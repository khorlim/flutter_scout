import 'dart:convert';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';

PerformanceEnvironment testPerformanceEnvironment() => PerformanceEnvironment(
  hardware: PerformanceHardware(
    model: 'Mac test reference',
    cpu: 'Apple test CPU 8-core',
    memoryBytes: 16 * 1024 * 1024 * 1024,
  ),
  hostOs: PerformanceHostOs(
    name: 'macOS',
    version: '26.0.1',
    architecture: 'arm64',
  ),
  toolchains: PerformanceToolchains(
    flutterVersion: '3.44.2',
    dartVersion: '3.12.2',
    platformSdkVersion: 'Xcode 26.0',
  ),
  buildMode: PerformanceBuildMode.debug,
  fixture: PerformanceFixture(
    appId: 'scout-test-app',
    appGitCommit: 'c' * 40,
    fixtureId: 'large-tree-reference',
    scenario: PerformanceScenario.actionOverhead,
    treeSizeNodes: 1200,
  ),
  viewport: PerformanceViewport(
    logicalWidth: 390,
    logicalHeight: 844,
    devicePixelRatio: 3,
  ),
  device: PerformanceDevice(
    platform: 'ios-simulator',
    model: 'iPhone test',
    osImage: 'iOS 26.0 build 23A123',
  ),
  measurement: PerformanceMeasurementMethod(
    clock: 'monotonic-process-stopwatch',
    method: 'single-action-bracketed-phases',
    collector: 'flutter-scout-evaluation',
    collectorVersion: '1.0.0-test',
    tokenEstimator: 'utf8_bytes_divisor_ceiling',
    estimatedUtf8BytesPerToken: 4,
  ),
);

PerformanceConfig testPerformanceConfig({
  bool ratified = false,
  int? repetitions,
  double comparisonTolerancePercent = 5,
}) {
  final environment = testPerformanceEnvironment();
  final measuredRepetitions = repetitions ?? (ratified ? 100 : 2);
  return PerformanceConfig(
    benchmarkId: 'performance-test',
    baseline: PerformanceCondition(
      conditionId: 'baseline',
      scoutGitCommit: 'a' * 40,
      cliVersion: '1.0.0',
      helperVersion: '0.1.0',
      protocolVersion: '15',
    ),
    candidate: PerformanceCondition(
      conditionId: 'candidate',
      scoutGitCommit: 'b' * 40,
      cliVersion: '2.0.0-dev.1',
      helperVersion: '0.2.0-dev.1',
      protocolVersion: '15',
    ),
    environment: environment,
    warmupIterations: 3,
    repetitions: measuredRepetitions,
    thresholds: PerformanceThresholds(
      status: ratified
          ? ThresholdRatificationStatus.ratified
          : ThresholdRatificationStatus.provisional,
      ratificationId: ratified ? 'reference-2026-08-20' : null,
      frozenEnvironmentSha256: ratified ? environment.sha256 : null,
      warmBriefInspectStandardP95Us: 300000,
      warmBriefInspectLargeTreeP95Us: 750000,
      actionOverheadP95Us: 250000,
      payloadP95EstimatedTokens: 1500,
      idleCpuMaxPercent: 1,
      incrementalRssMaxBytes: 20 * 1024 * 1024,
      frameTimeMedianRegressionMaxPercent: 5,
      enduranceMinDurationMs: 60 * 60 * 1000,
      enduranceMinActions: 1000,
      enduranceMaxGrowthBytes: 4 * 1024 * 1024,
      comparisonTolerancePercent: comparisonTolerancePercent,
    ),
  );
}

PerformanceRawSample testPerformanceSample({
  required PerformanceConfig config,
  required String conditionId,
  required int repetition,
  String? configSha256,
  bool observationEffect = false,
  PerformancePhaseTimings? phaseTimings,
  int? responsePayloadBytes,
}) {
  final candidate = conditionId == config.candidate.conditionId;
  final capturedAt = DateTime.utc(2026, 8, 20, 1, repetition);
  MeasurementProvenance provenance(String source, String target) =>
      MeasurementProvenance(
        source: source,
        method: 'deterministic-test-measurement',
        collectorVersion: '1.0.0-test',
        target: target,
        capturedAtUtc: capturedAt,
      );
  IdentityObservationEffect unchanged(String identity) =>
      IdentityObservationEffect(
        beforeIdentity: identity,
        afterIdentity: identity,
        mutationCount: 0,
      );

  final base = candidate ? 0 : 20;
  return PerformanceRawSample(
    sampleId: performanceSampleId(conditionId, repetition),
    configSha256: configSha256 ?? config.sha256,
    conditionId: conditionId,
    repetition: repetition,
    warmupIterationsCompleted: config.warmupIterations,
    capturedAtUtc: capturedAt,
    phaseTimings:
        phaseTimings ??
        PerformancePhaseTimings(
          connectUs: 100 + base + repetition,
          snapshotUs: 1000 + base + repetition,
          matchUs: 500 + base + repetition,
          dispatchUs: 300 + base + repetition,
          settleUs: 5000 + repetition,
          deltaUs: 600 + base + repetition,
          logsUs: 200 + base + repetition,
          serializeUs: 100 + base + repetition,
        ),
    responsePayloadBytes:
        responsePayloadBytes ?? (candidate ? 3800 : 4000) + repetition,
    resources: ResourceObservations(
      cpu: CpuObservation(
        idlePercent: candidate ? 0.3 : 0.4,
        activePercent: candidate ? 1.8 : 2,
        windowMs: 10000,
        provenance: provenance('host-process-profiler', 'scout-process'),
      ),
      memory: MemoryObservation(
        processRssBytes: candidate ? 48 * 1024 * 1024 : 50 * 1024 * 1024,
        incrementalRssBytes: candidate ? 9 * 1024 * 1024 : 10 * 1024 * 1024,
        peakRssBytes: 55 * 1024 * 1024,
        provenance: provenance('host-process-profiler', 'scout-process'),
      ),
      frameTime: FrameTimeObservation(
        frameCount: 600,
        medianUs: candidate ? 15800 : 16000,
        p95Us: candidate ? 18000 : 18500,
        provenance: provenance('flutter-frame-timing', 'fixture-app'),
      ),
      endurance: EnduranceObservation(
        durationMs: 60 * 60 * 1000,
        actionCount: 1000,
        crashCount: 0,
        crossoverCount: 0,
        deadlockCount: 0,
        startRssBytes: 50 * 1024 * 1024,
        endRssBytes: 51 * 1024 * 1024,
        peakRssBytes: 55 * 1024 * 1024,
        unboundedGrowthObserved: false,
        provenance: provenance('endurance-controller', 'scout-and-app'),
      ),
    ),
    observationEffects: ObservationEffects(
      focus: observationEffect
          ? IdentityObservationEffect(
              beforeIdentity: 'focus.none',
              afterIdentity: 'focus.field-name',
              mutationCount: 1,
            )
          : unchanged('focus.none'),
      pointerGesture: PointerGestureObservationEffect(
        activePointersBefore: 0,
        activePointersAfter: 0,
        pointerEventsDispatched: 0,
        gesturesDispatched: 0,
      ),
      route: unchanged('route.large-tree'),
      semantics: unchanged('sha256:${'d' * 64}'),
      overlay: OverlayObservationEffect(
        interceptingBefore: false,
        interceptingAfter: false,
        interceptionCount: 0,
        persistentInterceptionIntroduced: false,
      ),
      businessState: unchanged('sha256:${'e' * 64}'),
      syntheticFrameCount: 0,
      provenance: provenance('out-of-band-observation-auditor', 'fixture-app'),
    ),
  );
}

List<LoadedPerformanceSample> testPerformanceSamples(
  PerformanceConfig config, {
  String? mismatchedSampleId,
  bool candidateObservationEffect = false,
}) => [
  for (final condition in config.conditions)
    for (var repetition = 1; repetition <= config.repetitions; repetition++)
      _loaded(
        testPerformanceSample(
          config: config,
          conditionId: condition.conditionId,
          repetition: repetition,
          configSha256:
              performanceSampleId(condition.conditionId, repetition) ==
                  mismatchedSampleId
              ? 'f' * 64
              : null,
          observationEffect:
              candidateObservationEffect &&
              condition.conditionId == config.candidate.conditionId &&
              repetition == 1,
        ),
      ),
];

LoadedPerformanceSample loadedPerformanceSample(PerformanceRawSample sample) =>
    _loaded(sample);

LoadedPerformanceSample _loaded(PerformanceRawSample sample) {
  final bytes = utf8.encode(canonicalJsonEncode(sample.toJson()));
  return LoadedPerformanceSample(
    sourcePath: '/raw/${sample.sampleId}.json',
    fileSha256: sha256Bytes(bytes),
    rawBytes: bytes,
    sample: sample,
  );
}
