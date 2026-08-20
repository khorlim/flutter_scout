import 'dart:convert';
import 'dart:io';

import '../digests.dart';
import '../input_io.dart';
import '../json_support.dart';
import 'performance_config.dart';

const int performanceSampleSchemaVersion = 1;

const List<String> performancePhaseNames = [
  'connect',
  'snapshot',
  'match',
  'dispatch',
  'settle',
  'delta',
  'logs',
  'serialize',
];

class PerformancePhaseTimings {
  PerformancePhaseTimings({
    required this.connectUs,
    required this.snapshotUs,
    required this.matchUs,
    required this.dispatchUs,
    required this.settleUs,
    required this.deltaUs,
    required this.logsUs,
    required this.serializeUs,
  }) {
    for (final entry in toJson().entries) {
      if (entry.value < 0) {
        throw ArgumentError.value(
          entry.value,
          entry.key,
          'must be non-negative',
        );
      }
    }
  }

  final int connectUs;
  final int snapshotUs;
  final int matchUs;
  final int dispatchUs;
  final int settleUs;
  final int deltaUs;
  final int logsUs;
  final int serializeUs;

  int get actionOverheadExcludingSettleUs =>
      connectUs +
      snapshotUs +
      matchUs +
      dispatchUs +
      deltaUs +
      logsUs +
      serializeUs;

  int get totalUs => actionOverheadExcludingSettleUs + settleUs;

  int valueFor(String phase) => switch (phase) {
    'connect' => connectUs,
    'snapshot' => snapshotUs,
    'match' => matchUs,
    'dispatch' => dispatchUs,
    'settle' => settleUs,
    'delta' => deltaUs,
    'logs' => logsUs,
    'serialize' => serializeUs,
    _ => throw ArgumentError.value(phase, 'phase', 'unknown phase'),
  };

  factory PerformancePhaseTimings.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, performancePhaseNames.toSet(), path);
    int read(String name) =>
        expectJsonInt(json[name], '$path.$name', minimum: 0);
    return PerformancePhaseTimings(
      connectUs: read('connect'),
      snapshotUs: read('snapshot'),
      matchUs: read('match'),
      dispatchUs: read('dispatch'),
      settleUs: read('settle'),
      deltaUs: read('delta'),
      logsUs: read('logs'),
      serializeUs: read('serialize'),
    );
  }

  Map<String, int> toJson() => {
    'connect': connectUs,
    'snapshot': snapshotUs,
    'match': matchUs,
    'dispatch': dispatchUs,
    'settle': settleUs,
    'delta': deltaUs,
    'logs': logsUs,
    'serialize': serializeUs,
  };
}

class MeasurementProvenance {
  MeasurementProvenance({
    required this.source,
    required this.method,
    required this.collectorVersion,
    required this.target,
    required this.capturedAtUtc,
  }) {
    for (final entry in {
      'source': source,
      'method': method,
      'collectorVersion': collectorVersion,
      'target': target,
    }.entries) {
      if (entry.value.trim().isEmpty) {
        throw ArgumentError.value(entry.value, entry.key, 'must not be empty');
      }
    }
    _requireUtc(capturedAtUtc, 'capturedAtUtc');
  }

  final String source;
  final String method;
  final String collectorVersion;
  final String target;
  final DateTime capturedAtUtc;

  factory MeasurementProvenance.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'source',
      'method',
      'collectorVersion',
      'target',
      'capturedAtUtc',
    }, path);
    return MeasurementProvenance(
      source: expectJsonString(json['source'], '$path.source'),
      method: expectJsonString(json['method'], '$path.method'),
      collectorVersion: expectJsonString(
        json['collectorVersion'],
        '$path.collectorVersion',
      ),
      target: expectJsonString(json['target'], '$path.target'),
      capturedAtUtc: _parseUtc(json['capturedAtUtc'], '$path.capturedAtUtc'),
    );
  }

  Map<String, Object?> toJson() => {
    'source': source,
    'method': method,
    'collectorVersion': collectorVersion,
    'target': target,
    'capturedAtUtc': capturedAtUtc.toIso8601String(),
  };
}

class CpuObservation {
  CpuObservation({
    required this.idlePercent,
    required this.activePercent,
    required this.windowMs,
    required this.provenance,
  }) {
    _validatePercent(idlePercent, 'idlePercent');
    _validatePercent(activePercent, 'activePercent');
    _requirePositive(windowMs, 'windowMs');
  }

  final double idlePercent;
  final double activePercent;
  final int windowMs;
  final MeasurementProvenance provenance;

  factory CpuObservation.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'idlePercent',
      'activePercent',
      'windowMs',
      'provenance',
    }, path);
    return CpuObservation(
      idlePercent: _expectPercent(json['idlePercent'], '$path.idlePercent'),
      activePercent: _expectPercent(
        json['activePercent'],
        '$path.activePercent',
      ),
      windowMs: expectJsonInt(json['windowMs'], '$path.windowMs', minimum: 1),
      provenance: MeasurementProvenance.fromJson(
        json['provenance'],
        '$path.provenance',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'idlePercent': idlePercent,
    'activePercent': activePercent,
    'windowMs': windowMs,
    'provenance': provenance.toJson(),
  };
}

class MemoryObservation {
  MemoryObservation({
    required this.processRssBytes,
    required this.incrementalRssBytes,
    required this.peakRssBytes,
    required this.provenance,
  }) {
    _requireNonNegative(processRssBytes, 'processRssBytes');
    _requireNonNegative(incrementalRssBytes, 'incrementalRssBytes');
    _requireNonNegative(peakRssBytes, 'peakRssBytes');
    if (peakRssBytes < processRssBytes) {
      throw ArgumentError('peakRssBytes must be at least processRssBytes.');
    }
  }

  final int processRssBytes;
  final int incrementalRssBytes;
  final int peakRssBytes;
  final MeasurementProvenance provenance;

  factory MemoryObservation.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'processRssBytes',
      'incrementalRssBytes',
      'peakRssBytes',
      'provenance',
    }, path);
    return MemoryObservation(
      processRssBytes: expectJsonInt(
        json['processRssBytes'],
        '$path.processRssBytes',
        minimum: 0,
      ),
      incrementalRssBytes: expectJsonInt(
        json['incrementalRssBytes'],
        '$path.incrementalRssBytes',
        minimum: 0,
      ),
      peakRssBytes: expectJsonInt(
        json['peakRssBytes'],
        '$path.peakRssBytes',
        minimum: 0,
      ),
      provenance: MeasurementProvenance.fromJson(
        json['provenance'],
        '$path.provenance',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'processRssBytes': processRssBytes,
    'incrementalRssBytes': incrementalRssBytes,
    'peakRssBytes': peakRssBytes,
    'provenance': provenance.toJson(),
  };
}

class FrameTimeObservation {
  FrameTimeObservation({
    required this.frameCount,
    required this.medianUs,
    required this.p95Us,
    required this.provenance,
  }) {
    _requirePositive(frameCount, 'frameCount');
    _requireNonNegative(medianUs, 'medianUs');
    _requireNonNegative(p95Us, 'p95Us');
    if (p95Us < medianUs) {
      throw ArgumentError('p95Us must be at least medianUs.');
    }
  }

  final int frameCount;
  final int medianUs;
  final int p95Us;
  final MeasurementProvenance provenance;

  factory FrameTimeObservation.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'frameCount',
      'medianUs',
      'p95Us',
      'provenance',
    }, path);
    return FrameTimeObservation(
      frameCount: expectJsonInt(
        json['frameCount'],
        '$path.frameCount',
        minimum: 1,
      ),
      medianUs: expectJsonInt(json['medianUs'], '$path.medianUs', minimum: 0),
      p95Us: expectJsonInt(json['p95Us'], '$path.p95Us', minimum: 0),
      provenance: MeasurementProvenance.fromJson(
        json['provenance'],
        '$path.provenance',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'frameCount': frameCount,
    'medianUs': medianUs,
    'p95Us': p95Us,
    'provenance': provenance.toJson(),
  };
}

class EnduranceObservation {
  EnduranceObservation({
    required this.durationMs,
    required this.actionCount,
    required this.crashCount,
    required this.crossoverCount,
    required this.deadlockCount,
    required this.startRssBytes,
    required this.endRssBytes,
    required this.peakRssBytes,
    required this.unboundedGrowthObserved,
    required this.provenance,
  }) {
    _requirePositive(durationMs, 'durationMs');
    _requirePositive(actionCount, 'actionCount');
    for (final entry in {
      'crashCount': crashCount,
      'crossoverCount': crossoverCount,
      'deadlockCount': deadlockCount,
      'startRssBytes': startRssBytes,
      'endRssBytes': endRssBytes,
      'peakRssBytes': peakRssBytes,
    }.entries) {
      _requireNonNegative(entry.value, entry.key);
    }
    if (peakRssBytes < startRssBytes || peakRssBytes < endRssBytes) {
      throw ArgumentError('peakRssBytes must cover start and end RSS.');
    }
  }

  final int durationMs;
  final int actionCount;
  final int crashCount;
  final int crossoverCount;
  final int deadlockCount;
  final int startRssBytes;
  final int endRssBytes;
  final int peakRssBytes;
  final bool unboundedGrowthObserved;
  final MeasurementProvenance provenance;

  int get growthBytes => endRssBytes - startRssBytes;

  bool get clean =>
      crashCount == 0 &&
      crossoverCount == 0 &&
      deadlockCount == 0 &&
      !unboundedGrowthObserved;

  factory EnduranceObservation.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'durationMs',
      'actionCount',
      'crashCount',
      'crossoverCount',
      'deadlockCount',
      'startRssBytes',
      'endRssBytes',
      'peakRssBytes',
      'unboundedGrowthObserved',
      'provenance',
    }, path);
    int read(String name, {int minimum = 0}) =>
        expectJsonInt(json[name], '$path.$name', minimum: minimum);
    return EnduranceObservation(
      durationMs: read('durationMs', minimum: 1),
      actionCount: read('actionCount', minimum: 1),
      crashCount: read('crashCount'),
      crossoverCount: read('crossoverCount'),
      deadlockCount: read('deadlockCount'),
      startRssBytes: read('startRssBytes'),
      endRssBytes: read('endRssBytes'),
      peakRssBytes: read('peakRssBytes'),
      unboundedGrowthObserved: expectJsonBool(
        json['unboundedGrowthObserved'],
        '$path.unboundedGrowthObserved',
      ),
      provenance: MeasurementProvenance.fromJson(
        json['provenance'],
        '$path.provenance',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'durationMs': durationMs,
    'actionCount': actionCount,
    'crashCount': crashCount,
    'crossoverCount': crossoverCount,
    'deadlockCount': deadlockCount,
    'startRssBytes': startRssBytes,
    'endRssBytes': endRssBytes,
    'peakRssBytes': peakRssBytes,
    'unboundedGrowthObserved': unboundedGrowthObserved,
    'provenance': provenance.toJson(),
  };
}

class ResourceObservations {
  const ResourceObservations({
    required this.cpu,
    required this.memory,
    required this.frameTime,
    required this.endurance,
  });

  final CpuObservation cpu;
  final MemoryObservation memory;
  final FrameTimeObservation frameTime;
  final EnduranceObservation endurance;

  factory ResourceObservations.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'cpu',
      'memory',
      'frameTime',
      'endurance',
    }, path);
    return ResourceObservations(
      cpu: CpuObservation.fromJson(json['cpu'], '$path.cpu'),
      memory: MemoryObservation.fromJson(json['memory'], '$path.memory'),
      frameTime: FrameTimeObservation.fromJson(
        json['frameTime'],
        '$path.frameTime',
      ),
      endurance: EnduranceObservation.fromJson(
        json['endurance'],
        '$path.endurance',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'cpu': cpu.toJson(),
    'memory': memory.toJson(),
    'frameTime': frameTime.toJson(),
    'endurance': endurance.toJson(),
  };
}

class IdentityObservationEffect {
  IdentityObservationEffect({
    required this.beforeIdentity,
    required this.afterIdentity,
    required this.mutationCount,
  }) {
    if (beforeIdentity.trim().isEmpty || afterIdentity.trim().isEmpty) {
      throw ArgumentError('Observation identities must not be empty.');
    }
    _requireNonNegative(mutationCount, 'mutationCount');
  }

  final String beforeIdentity;
  final String afterIdentity;
  final int mutationCount;

  bool get hasEffect => beforeIdentity != afterIdentity || mutationCount != 0;

  factory IdentityObservationEffect.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'beforeIdentity',
      'afterIdentity',
      'mutationCount',
    }, path);
    return IdentityObservationEffect(
      beforeIdentity: expectJsonString(
        json['beforeIdentity'],
        '$path.beforeIdentity',
      ),
      afterIdentity: expectJsonString(
        json['afterIdentity'],
        '$path.afterIdentity',
      ),
      mutationCount: expectJsonInt(
        json['mutationCount'],
        '$path.mutationCount',
        minimum: 0,
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'beforeIdentity': beforeIdentity,
    'afterIdentity': afterIdentity,
    'mutationCount': mutationCount,
  };
}

class PointerGestureObservationEffect {
  PointerGestureObservationEffect({
    required this.activePointersBefore,
    required this.activePointersAfter,
    required this.pointerEventsDispatched,
    required this.gesturesDispatched,
  }) {
    for (final entry in toJson().entries) {
      _requireNonNegative(entry.value, entry.key);
    }
  }

  final int activePointersBefore;
  final int activePointersAfter;
  final int pointerEventsDispatched;
  final int gesturesDispatched;

  bool get hasEffect =>
      activePointersBefore != activePointersAfter ||
      pointerEventsDispatched != 0 ||
      gesturesDispatched != 0;

  factory PointerGestureObservationEffect.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'activePointersBefore',
      'activePointersAfter',
      'pointerEventsDispatched',
      'gesturesDispatched',
    }, path);
    int read(String name) =>
        expectJsonInt(json[name], '$path.$name', minimum: 0);
    return PointerGestureObservationEffect(
      activePointersBefore: read('activePointersBefore'),
      activePointersAfter: read('activePointersAfter'),
      pointerEventsDispatched: read('pointerEventsDispatched'),
      gesturesDispatched: read('gesturesDispatched'),
    );
  }

  Map<String, int> toJson() => {
    'activePointersBefore': activePointersBefore,
    'activePointersAfter': activePointersAfter,
    'pointerEventsDispatched': pointerEventsDispatched,
    'gesturesDispatched': gesturesDispatched,
  };
}

class OverlayObservationEffect {
  OverlayObservationEffect({
    required this.interceptingBefore,
    required this.interceptingAfter,
    required this.interceptionCount,
    required this.persistentInterceptionIntroduced,
  }) {
    _requireNonNegative(interceptionCount, 'interceptionCount');
    final observedPersistentIntroduction =
        !interceptingBefore && interceptingAfter;
    if (persistentInterceptionIntroduced != observedPersistentIntroduction) {
      throw ArgumentError(
        'persistentInterceptionIntroduced must equal the observed before/after '
        'transition.',
      );
    }
  }

  final bool interceptingBefore;
  final bool interceptingAfter;
  final int interceptionCount;
  final bool persistentInterceptionIntroduced;

  bool get hasEffect =>
      interceptingBefore != interceptingAfter ||
      interceptionCount != 0 ||
      persistentInterceptionIntroduced;

  factory OverlayObservationEffect.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'interceptingBefore',
      'interceptingAfter',
      'interceptionCount',
      'persistentInterceptionIntroduced',
    }, path);
    return OverlayObservationEffect(
      interceptingBefore: expectJsonBool(
        json['interceptingBefore'],
        '$path.interceptingBefore',
      ),
      interceptingAfter: expectJsonBool(
        json['interceptingAfter'],
        '$path.interceptingAfter',
      ),
      interceptionCount: expectJsonInt(
        json['interceptionCount'],
        '$path.interceptionCount',
        minimum: 0,
      ),
      persistentInterceptionIntroduced: expectJsonBool(
        json['persistentInterceptionIntroduced'],
        '$path.persistentInterceptionIntroduced',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'interceptingBefore': interceptingBefore,
    'interceptingAfter': interceptingAfter,
    'interceptionCount': interceptionCount,
    'persistentInterceptionIntroduced': persistentInterceptionIntroduced,
  };
}

class ObservationEffects {
  ObservationEffects({
    required this.focus,
    required this.pointerGesture,
    required this.route,
    required this.semantics,
    required this.overlay,
    required this.businessState,
    required this.syntheticFrameCount,
    required this.provenance,
  }) {
    _requireNonNegative(syntheticFrameCount, 'syntheticFrameCount');
  }

  final IdentityObservationEffect focus;
  final PointerGestureObservationEffect pointerGesture;
  final IdentityObservationEffect route;
  final IdentityObservationEffect semantics;
  final OverlayObservationEffect overlay;
  final IdentityObservationEffect businessState;
  final int syntheticFrameCount;
  final MeasurementProvenance provenance;

  List<String> get effectKinds => [
    if (focus.hasEffect) 'focus',
    if (pointerGesture.hasEffect) 'pointer_gesture',
    if (route.hasEffect) 'route',
    if (semantics.hasEffect) 'semantics',
    if (overlay.hasEffect) 'overlay_interception',
    if (businessState.hasEffect) 'business_state',
    if (syntheticFrameCount != 0) 'synthetic_frames',
  ];

  bool get hasEffect => effectKinds.isNotEmpty;

  factory ObservationEffects.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'focus',
      'pointerGesture',
      'route',
      'semantics',
      'overlay',
      'businessState',
      'syntheticFrameCount',
      'provenance',
    }, path);
    return ObservationEffects(
      focus: IdentityObservationEffect.fromJson(json['focus'], '$path.focus'),
      pointerGesture: PointerGestureObservationEffect.fromJson(
        json['pointerGesture'],
        '$path.pointerGesture',
      ),
      route: IdentityObservationEffect.fromJson(json['route'], '$path.route'),
      semantics: IdentityObservationEffect.fromJson(
        json['semantics'],
        '$path.semantics',
      ),
      overlay: OverlayObservationEffect.fromJson(
        json['overlay'],
        '$path.overlay',
      ),
      businessState: IdentityObservationEffect.fromJson(
        json['businessState'],
        '$path.businessState',
      ),
      syntheticFrameCount: expectJsonInt(
        json['syntheticFrameCount'],
        '$path.syntheticFrameCount',
        minimum: 0,
      ),
      provenance: MeasurementProvenance.fromJson(
        json['provenance'],
        '$path.provenance',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'focus': focus.toJson(),
    'pointerGesture': pointerGesture.toJson(),
    'route': route.toJson(),
    'semantics': semantics.toJson(),
    'overlay': overlay.toJson(),
    'businessState': businessState.toJson(),
    'syntheticFrameCount': syntheticFrameCount,
    'provenance': provenance.toJson(),
  };
}

class PerformanceRawSample {
  PerformanceRawSample({
    required this.sampleId,
    required this.configSha256,
    required this.conditionId,
    required this.repetition,
    required this.warmupIterationsCompleted,
    required this.capturedAtUtc,
    required this.phaseTimings,
    required this.responsePayloadBytes,
    required this.resources,
    required this.observationEffects,
  }) {
    validateIdentifier(sampleId, 'sampleId');
    _validateSha256(configSha256, 'configSha256');
    validateIdentifier(conditionId, 'conditionId');
    _requirePositive(repetition, 'repetition');
    _requirePositive(warmupIterationsCompleted, 'warmupIterationsCompleted');
    _requireUtc(capturedAtUtc, 'capturedAtUtc');
    _requireNonNegative(responsePayloadBytes, 'responsePayloadBytes');
    final expectedId = performanceSampleId(conditionId, repetition);
    if (sampleId != expectedId) {
      throw ArgumentError(
        'sampleId must be deterministic: expected `$expectedId`, got '
        '`$sampleId`.',
      );
    }
  }

  final String sampleId;
  final String configSha256;
  final String conditionId;
  final int repetition;
  final int warmupIterationsCompleted;
  final DateTime capturedAtUtc;
  final PerformancePhaseTimings phaseTimings;
  final int responsePayloadBytes;
  final ResourceObservations resources;
  final ObservationEffects observationEffects;

  factory PerformanceRawSample.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$');
    rejectUnknownKeys(json, const {
      'schemaVersion',
      'sampleId',
      'configSha256',
      'conditionId',
      'repetition',
      'warmupIterationsCompleted',
      'capturedAtUtc',
      'phaseTimingsUs',
      'responsePayloadBytes',
      'resources',
      'observationEffects',
    }, r'$');
    final version = expectJsonInt(json['schemaVersion'], r'$.schemaVersion');
    if (version != performanceSampleSchemaVersion) {
      throw FormatException(
        'Unsupported performance sample schemaVersion $version; expected '
        '$performanceSampleSchemaVersion.',
      );
    }
    return PerformanceRawSample(
      sampleId: expectJsonString(json['sampleId'], r'$.sampleId'),
      configSha256: expectJsonString(json['configSha256'], r'$.configSha256'),
      conditionId: expectJsonString(json['conditionId'], r'$.conditionId'),
      repetition: expectJsonInt(
        json['repetition'],
        r'$.repetition',
        minimum: 1,
      ),
      warmupIterationsCompleted: expectJsonInt(
        json['warmupIterationsCompleted'],
        r'$.warmupIterationsCompleted',
        minimum: 1,
      ),
      capturedAtUtc: _parseUtc(json['capturedAtUtc'], r'$.capturedAtUtc'),
      phaseTimings: PerformancePhaseTimings.fromJson(
        json['phaseTimingsUs'],
        r'$.phaseTimingsUs',
      ),
      responsePayloadBytes: expectJsonInt(
        json['responsePayloadBytes'],
        r'$.responsePayloadBytes',
        minimum: 0,
      ),
      resources: ResourceObservations.fromJson(
        json['resources'],
        r'$.resources',
      ),
      observationEffects: ObservationEffects.fromJson(
        json['observationEffects'],
        r'$.observationEffects',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': performanceSampleSchemaVersion,
    'sampleId': sampleId,
    'configSha256': configSha256,
    'conditionId': conditionId,
    'repetition': repetition,
    'warmupIterationsCompleted': warmupIterationsCompleted,
    'capturedAtUtc': capturedAtUtc.toIso8601String(),
    'phaseTimingsUs': phaseTimings.toJson(),
    'responsePayloadBytes': responsePayloadBytes,
    'resources': resources.toJson(),
    'observationEffects': observationEffects.toJson(),
  };
}

class LoadedPerformanceSample {
  LoadedPerformanceSample({
    required this.sourcePath,
    required this.fileSha256,
    required List<int> rawBytes,
    required this.sample,
  }) : rawBytes = List<int>.unmodifiable(rawBytes);

  final String sourcePath;
  final String fileSha256;
  final List<int> rawBytes;
  final PerformanceRawSample sample;

  Map<String, Object?> inventoryJson() => {
    'sampleId': sample.sampleId,
    'sourceFile': Uri.file(sourcePath).pathSegments.last,
    'fileSha256': fileSha256,
    'byteLength': rawBytes.length,
  };
}

class ImmutablePerformanceSampleLoader {
  const ImmutablePerformanceSampleLoader({
    this.maximumSampleFiles = 10000,
    this.maximumSampleBytes = 4 * 1024 * 1024,
    this.maximumArchiveBytes = 256 * 1024 * 1024,
  }) : assert(maximumSampleFiles > 0),
       assert(maximumSampleBytes > 0),
       assert(maximumArchiveBytes >= maximumSampleBytes);

  final int maximumSampleFiles;
  final int maximumSampleBytes;
  final int maximumArchiveBytes;

  Future<List<LoadedPerformanceSample>> load(Directory directory) async {
    final directoryType = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (directoryType != FileSystemEntityType.directory) {
      throw FormatException(
        'Performance sample archive `${directory.path}` must be a directory '
        'and must not be a symbolic link.',
      );
    }
    final entities = await directory.list(followLinks: false).toList()
      ..sort((first, second) => first.path.compareTo(second.path));
    if (entities.isEmpty) {
      throw FormatException('Performance sample archive is empty.');
    }
    if (entities.length > maximumSampleFiles) {
      throw FormatException(
        'Performance sample archive exceeds the '
        '$maximumSampleFiles-file bound.',
      );
    }
    final loaded = <LoadedPerformanceSample>[];
    final ids = <String>{};
    var totalBytes = 0;
    for (final entity in entities) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.file || !entity.path.endsWith('.json')) {
        throw FormatException(
          'Archive entries must be regular `.json` files; found '
          '`${entity.path}`.',
        );
      }
      final file = File(entity.path);
      final bytes = await readStableBoundedRegularFile(
        file,
        maximumBytes: maximumSampleBytes,
      );
      totalBytes += bytes.length;
      if (totalBytes > maximumArchiveBytes) {
        throw FormatException(
          'Performance sample archive exceeds the '
          '$maximumArchiveBytes-byte aggregate bound.',
        );
      }
      final text = utf8.decode(bytes, allowMalformed: false);
      final decoded = jsonDecode(text);
      final sample = PerformanceRawSample.fromJson(decoded);
      final fileName = entity.uri.pathSegments.last;
      if (fileName != '${sample.sampleId}.json') {
        throw FormatException(
          'Raw sample file `$fileName` must be named '
          '`${sample.sampleId}.json`.',
        );
      }
      if (!ids.add(sample.sampleId)) {
        throw FormatException('Duplicate raw sample `${sample.sampleId}`.');
      }
      loaded.add(
        LoadedPerformanceSample(
          sourcePath: entity.path,
          fileSha256: sha256Bytes(bytes),
          rawBytes: bytes,
          sample: sample,
        ),
      );
    }
    return List<LoadedPerformanceSample>.unmodifiable(loaded);
  }
}

void _validateSha256(String value, String path) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw FormatException('$path must be a lowercase SHA-256 digest.');
  }
}

DateTime _parseUtc(Object? value, String path) {
  final text = expectJsonString(value, path);
  if (!text.endsWith('Z')) {
    throw FormatException('$path must use an explicit UTC `Z` timestamp.');
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null || !parsed.isUtc) {
    throw FormatException('$path must be a valid UTC timestamp.');
  }
  return parsed;
}

void _requireUtc(DateTime value, String path) {
  if (!value.isUtc) {
    throw ArgumentError.value(value, path, 'must be UTC');
  }
}

double _expectPercent(Object? value, String path) {
  if (value is! num || !value.isFinite || value < 0 || value > 100) {
    throw FormatException('$path must be finite and between 0 and 100.');
  }
  return value.toDouble();
}

void _validatePercent(double value, String path) {
  if (!value.isFinite || value < 0 || value > 100) {
    throw ArgumentError.value(value, path, 'must be between 0 and 100');
  }
}

void _requirePositive(int value, String path) {
  if (value < 1) {
    throw ArgumentError.value(value, path, 'must be positive');
  }
}

void _requireNonNegative(int value, String path) {
  if (value < 0) {
    throw ArgumentError.value(value, path, 'must be non-negative');
  }
}
