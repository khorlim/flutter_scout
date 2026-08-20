import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import '../digests.dart';
import '../json_support.dart';
import '../performance/performance_sample.dart';
import 'endurance_config.dart';

const int enduranceArchiveSchemaVersion = 1;

enum EnduranceRunStatus {
  completed('completed'),
  productFailure('product_failure'),
  interrupted('interrupted'),
  harnessInvalid('harness_invalid');

  const EnduranceRunStatus(this.jsonName);

  final String jsonName;

  static EnduranceRunStatus parse(Object? value, String path) {
    for (final status in values) {
      if (status.jsonName == value) return status;
    }
    throw FormatException('$path contains an unknown endurance run status.');
  }
}

enum EnduranceComponentStatus {
  pass('pass'),
  fail('fail'),
  unmeasured('unmeasured');

  const EnduranceComponentStatus(this.jsonName);

  final String jsonName;

  static EnduranceComponentStatus parse(Object? value, String path) {
    for (final status in values) {
      if (status.jsonName == value) return status;
    }
    throw FormatException('$path contains an unknown component status.');
  }
}

enum EnduranceFailureOwner {
  harness('harness'),
  product('product'),
  interruption('interruption'),
  evidenceArchive('evidence_archive');

  const EnduranceFailureOwner(this.jsonName);

  final String jsonName;

  static EnduranceFailureOwner parse(Object? value, String path) {
    for (final owner in values) {
      if (owner.jsonName == value) return owner;
    }
    throw FormatException('$path contains an unknown failure owner.');
  }
}

enum EnduranceFailureKind {
  controllerIdentityMismatch('controller_identity_mismatch'),
  setupFailed('setup_failed'),
  setupNotFresh('setup_not_fresh'),
  baselineFailed('baseline_failed'),
  probeFailed('probe_failed'),
  teardownFailed('teardown_failed'),
  teardownNotClean('teardown_not_clean'),
  clockRegressed('clock_regressed'),
  runnerCancelled('runner_cancelled'),
  hardBoundReached('hard_bound_reached'),
  commandLaunchFailed('command_launch_failed'),
  commandFailed('command_failed'),
  outputTruncated('output_truncated'),
  malformedResponse('malformed_response'),
  missingSafetyEvidence('missing_safety_evidence'),
  postconditionFailed('postcondition_failed'),
  uncertainDispatch('uncertain_dispatch'),
  blockingRuntimeSignal('blocking_runtime_signal'),
  appCrash('app_crash'),
  deadlock('deadlock'),
  sessionCrossover('session_crossover'),
  runCrossover('run_crossover'),
  runtimeCrossover('runtime_crossover'),
  processCrossover('process_crossover'),
  stateRegressed('state_regressed'),
  logCursorRegressed('log_cursor_regressed'),
  noProgress('no_progress'),
  memoryBoundExceeded('memory_bound_exceeded'),
  unboundedMemoryGrowth('unbounded_memory_growth'),
  archiveIncomplete('archive_incomplete');

  const EnduranceFailureKind(this.jsonName);

  final String jsonName;

  static EnduranceFailureKind parse(Object? value, String path) {
    for (final kind in values) {
      if (kind.jsonName == value) return kind;
    }
    throw FormatException('$path contains an unknown endurance failure kind.');
  }
}

class EnduranceFailure {
  EnduranceFailure({
    required this.kind,
    required this.owner,
    required this.releaseBlocking,
    required this.message,
    required this.sequence,
  }) {
    if (message.trim().isEmpty) {
      throw ArgumentError.value(message, 'message', 'must not be empty');
    }
    if (sequence != null && sequence! < 0) {
      throw ArgumentError.value(sequence, 'sequence');
    }
    if (owner == EnduranceFailureOwner.harness && releaseBlocking) {
      throw ArgumentError(
        'Invalid harness evidence must not be reported as a product blocker.',
      );
    }
  }

  final EnduranceFailureKind kind;
  final EnduranceFailureOwner owner;
  final bool releaseBlocking;
  final String message;
  final int? sequence;

  factory EnduranceFailure.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'kind',
      'owner',
      'releaseBlocking',
      'message',
      'sequence',
    }, path);
    final sequence = json['sequence'];
    return EnduranceFailure(
      kind: EnduranceFailureKind.parse(json['kind'], '$path.kind'),
      owner: EnduranceFailureOwner.parse(json['owner'], '$path.owner'),
      releaseBlocking: expectJsonBool(
        json['releaseBlocking'],
        '$path.releaseBlocking',
      ),
      message: expectJsonString(json['message'], '$path.message'),
      sequence: sequence == null
          ? null
          : expectJsonInt(sequence, '$path.sequence', minimum: 0),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.jsonName,
    'owner': owner.jsonName,
    'releaseBlocking': releaseBlocking,
    'message': message,
    'sequence': sequence,
  };
}

class EnduranceCorrelation {
  EnduranceCorrelation({
    required this.sessionName,
    required this.runId,
    required this.runtimeInstanceId,
    required this.processId,
    required this.fixtureGeneration,
  }) {
    validateIdentifier(sessionName, 'sessionName');
    _requireNonEmpty(runId, 'runId');
    _requireNonEmpty(runtimeInstanceId, 'runtimeInstanceId');
    if (processId < 1) {
      throw ArgumentError.value(processId, 'processId', 'must be positive');
    }
    if (fixtureGeneration < 0) {
      throw ArgumentError.value(fixtureGeneration, 'fixtureGeneration');
    }
  }

  final String sessionName;
  final String runId;
  final String runtimeInstanceId;
  final int processId;
  final int fixtureGeneration;

  factory EnduranceCorrelation.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'sessionName',
      'runId',
      'runtimeInstanceId',
      'processId',
      'fixtureGeneration',
    }, path);
    return EnduranceCorrelation(
      sessionName: expectJsonString(json['sessionName'], '$path.sessionName'),
      runId: expectJsonString(json['runId'], '$path.runId'),
      runtimeInstanceId: expectJsonString(
        json['runtimeInstanceId'],
        '$path.runtimeInstanceId',
      ),
      processId: expectJsonInt(
        json['processId'],
        '$path.processId',
        minimum: 1,
      ),
      fixtureGeneration: expectJsonInt(
        json['fixtureGeneration'],
        '$path.fixtureGeneration',
        minimum: 0,
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'sessionName': sessionName,
    'runId': runId,
    'runtimeInstanceId': runtimeInstanceId,
    'processId': processId,
    'fixtureGeneration': fixtureGeneration,
  };
}

class EnduranceSetupObservation {
  EnduranceSetupObservation({
    required this.freshSetup,
    required this.correlation,
    required this.capturedAtUtc,
    required this.setupFixtureSha256,
  }) {
    _requireUtc(capturedAtUtc, 'capturedAtUtc');
    _validateSha256(setupFixtureSha256, 'setupFixtureSha256');
  }

  final bool freshSetup;
  final EnduranceCorrelation correlation;
  final DateTime capturedAtUtc;
  final String setupFixtureSha256;

  Map<String, Object?> toJson() => <String, Object?>{
    'freshSetup': freshSetup,
    'correlation': correlation.toJson(),
    'capturedAtUtc': capturedAtUtc.toIso8601String(),
    'setupFixtureSha256': setupFixtureSha256,
  };
}

class EnduranceResourceProbe {
  EnduranceResourceProbe({
    required this.sequence,
    required this.correlation,
    required this.capturedAtUtc,
    required this.progressSignature,
    required this.processAlive,
    required this.crashCount,
    required this.crossoverCount,
    required this.deadlockCount,
    required this.blockingSignalCount,
    required this.cpu,
    required this.memory,
    required this.frameTime,
  }) {
    if (sequence < 0) {
      throw ArgumentError.value(sequence, 'sequence');
    }
    _requireUtc(capturedAtUtc, 'capturedAtUtc');
    _validateSha256(progressSignature, 'progressSignature');
    for (final entry in <String, int>{
      'crashCount': crashCount,
      'crossoverCount': crossoverCount,
      'deadlockCount': deadlockCount,
      'blockingSignalCount': blockingSignalCount,
    }.entries) {
      if (entry.value < 0) {
        throw ArgumentError.value(entry.value, entry.key);
      }
    }
  }

  final int sequence;
  final EnduranceCorrelation correlation;
  final DateTime capturedAtUtc;
  final String progressSignature;
  final bool processAlive;
  final int crashCount;
  final int crossoverCount;
  final int deadlockCount;
  final int blockingSignalCount;
  final CpuObservation cpu;
  final MemoryObservation memory;
  final FrameTimeObservation frameTime;

  Map<String, Object?> toJson() => <String, Object?>{
    'sequence': sequence,
    'correlation': correlation.toJson(),
    'capturedAtUtc': capturedAtUtc.toIso8601String(),
    'progressSignature': progressSignature,
    'processAlive': processAlive,
    'crashCount': crashCount,
    'crossoverCount': crossoverCount,
    'deadlockCount': deadlockCount,
    'blockingSignalCount': blockingSignalCount,
    'cpu': cpu.toJson(),
    'memory': memory.toJson(),
    'frameTime': frameTime.toJson(),
  };
}

class EnduranceTeardownObservation {
  EnduranceTeardownObservation({
    required this.attempted,
    required this.clean,
    required this.anchorCorrelation,
    required this.teardownFixtureSha256,
    required this.teardownGeneration,
    required this.capturedAtUtc,
  }) {
    _validateSha256(teardownFixtureSha256, 'teardownFixtureSha256');
    if (teardownGeneration <= anchorCorrelation.fixtureGeneration) {
      throw ArgumentError(
        'teardownGeneration must advance beyond the setup fixture generation.',
      );
    }
    _requireUtc(capturedAtUtc, 'capturedAtUtc');
  }

  final bool attempted;
  final bool clean;
  final EnduranceCorrelation anchorCorrelation;
  final String teardownFixtureSha256;
  final int teardownGeneration;
  final DateTime capturedAtUtc;

  Map<String, Object?> toJson() => <String, Object?>{
    'attempted': attempted,
    'clean': clean,
    'anchorCorrelation': anchorCorrelation.toJson(),
    'teardownFixtureSha256': teardownFixtureSha256,
    'teardownGeneration': teardownGeneration,
    'capturedAtUtc': capturedAtUtc.toIso8601String(),
  };
}

class EnduranceProbeRequest {
  const EnduranceProbeRequest({
    required this.enduranceRunId,
    required this.sequence,
    required this.actionId,
    required this.anchor,
  });

  final String enduranceRunId;
  final int sequence;
  final String actionId;
  final EnduranceCorrelation anchor;
}

abstract interface class EnduranceHarnessController {
  EnduranceHarnessIdentity get identity;

  Future<EnduranceSetupObservation> setUp(EnduranceConfig config);

  Future<EnduranceResourceProbe> probe(EnduranceProbeRequest request);

  Future<EnduranceTeardownObservation> tearDown({
    required EnduranceConfig config,
    required EnduranceCorrelation anchor,
  });
}

abstract interface class EnduranceClock {
  DateTime get utcNow;

  int get monotonicMicroseconds;
}

class SystemEnduranceClock implements EnduranceClock {
  SystemEnduranceClock()
    : _startedAtUtc = DateTime.now().toUtc(),
      _stopwatch = (Stopwatch()..start());

  final DateTime _startedAtUtc;
  final Stopwatch _stopwatch;

  @override
  int get monotonicMicroseconds => _stopwatch.elapsedMicroseconds;

  @override
  DateTime get utcNow => _startedAtUtc.add(_stopwatch.elapsed);
}

abstract interface class EnduranceCancellationSignal {
  bool get isCancelled;

  String? get reason;
}

class MutableEnduranceCancellationSignal
    implements EnduranceCancellationSignal {
  bool _cancelled = false;
  String? _reason;

  @override
  bool get isCancelled => _cancelled;

  @override
  String? get reason => _reason;

  void cancel([String reason = 'The endurance run was cancelled.']) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
  }
}

class NeverCancelledEnduranceSignal implements EnduranceCancellationSignal {
  const NeverCancelledEnduranceSignal();

  @override
  bool get isCancelled => false;

  @override
  String? get reason => null;
}

class EnduranceCommandEvidence {
  EnduranceCommandEvidence({
    required this.ok,
    required this.commandId,
    required this.commandName,
    required this.runId,
    required this.runtimeInstanceId,
    required this.stateGeneration,
    required this.logCursor,
    required this.phaseTimings,
    required this.executorElapsedUs,
    required this.stdoutBytes,
    required this.stderrBytes,
    required this.stdoutSha256,
    required this.stderrSha256,
    required this.stdout,
    required this.stderr,
    required this.transport,
    required this.dispatch,
    required this.observation,
    required this.postcondition,
    required this.runtimeHealth,
    required this.structuredErrorCode,
  }) {
    for (final entry in <String, String>{
      'commandId': commandId,
      'commandName': commandName,
      'runId': runId,
      'runtimeInstanceId': runtimeInstanceId,
    }.entries) {
      _requireNonEmpty(entry.value, entry.key);
    }
    if (stateGeneration < 0 ||
        logCursor < 0 ||
        executorElapsedUs < 0 ||
        stdoutBytes < 0 ||
        stderrBytes < 0) {
      throw ArgumentError('Command evidence counters must be non-negative.');
    }
    _validateSha256(stdoutSha256, 'stdoutSha256');
    _validateSha256(stderrSha256, 'stderrSha256');
    if (utf8.encode(stdout).length != stdoutBytes ||
        utf8.encode(stderr).length != stderrBytes) {
      throw ArgumentError('Command byte counts must match exact UTF-8 output.');
    }
    if (sha256Bytes(utf8.encode(stdout)) != stdoutSha256 ||
        sha256Bytes(utf8.encode(stderr)) != stderrSha256) {
      throw ArgumentError('Command output digests must match exact bytes.');
    }
  }

  final bool ok;
  final String commandId;
  final String commandName;
  final String runId;
  final String runtimeInstanceId;
  final int stateGeneration;
  final int logCursor;
  final PerformancePhaseTimings phaseTimings;
  final int executorElapsedUs;
  final int stdoutBytes;
  final int stderrBytes;
  final String stdoutSha256;
  final String stderrSha256;
  final String stdout;
  final String stderr;
  final String? transport;
  final String? dispatch;
  final String? observation;
  final String? postcondition;
  final String? runtimeHealth;
  final String? structuredErrorCode;

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': ok,
    'commandId': commandId,
    'commandName': commandName,
    'runId': runId,
    'runtimeInstanceId': runtimeInstanceId,
    'stateGeneration': stateGeneration,
    'logCursor': logCursor,
    'phaseTimingsUs': phaseTimings.toJson(),
    'executorElapsedUs': executorElapsedUs,
    'stdoutBytes': stdoutBytes,
    'stderrBytes': stderrBytes,
    'stdoutSha256': stdoutSha256,
    'stderrSha256': stderrSha256,
    'stdout': stdout,
    'stderr': stderr,
    'transport': transport,
    'dispatch': dispatch,
    'observation': observation,
    'postcondition': postcondition,
    'runtimeHealth': runtimeHealth,
    'structuredErrorCode': structuredErrorCode,
  };
}

class EnduranceStepRecord {
  EnduranceStepRecord({
    required this.sequence,
    required this.actionId,
    required this.mutating,
    required this.requiresProgress,
    required this.argumentsSha256,
    required this.startedAtUtc,
    required this.finishedAtUtc,
    required this.elapsedUs,
    required this.command,
    required this.probe,
    required this.noProgressStreak,
    required this.previousRecordSha256,
  }) {
    if (sequence < 1 || elapsedUs < 0 || noProgressStreak < 0) {
      throw ArgumentError('Invalid endurance step counters.');
    }
    _requireUtc(startedAtUtc, 'startedAtUtc');
    _requireUtc(finishedAtUtc, 'finishedAtUtc');
    if (finishedAtUtc.isBefore(startedAtUtc)) {
      throw ArgumentError('Step finishedAtUtc cannot precede startedAtUtc.');
    }
    _validateSha256(argumentsSha256, 'argumentsSha256');
    if (previousRecordSha256 != null) {
      _validateSha256(previousRecordSha256!, 'previousRecordSha256');
    }
  }

  final int sequence;
  final String actionId;
  final bool mutating;
  final bool requiresProgress;
  final String argumentsSha256;
  final DateTime startedAtUtc;
  final DateTime finishedAtUtc;
  final int elapsedUs;
  final EnduranceCommandEvidence command;
  final EnduranceResourceProbe probe;
  final int noProgressStreak;
  final String? previousRecordSha256;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': enduranceArchiveSchemaVersion,
    'recordType': 'step',
    'sequence': sequence,
    'actionId': actionId,
    'mutating': mutating,
    'requiresProgress': requiresProgress,
    'argumentsSha256': argumentsSha256,
    'startedAtUtc': startedAtUtc.toIso8601String(),
    'finishedAtUtc': finishedAtUtc.toIso8601String(),
    'elapsedUs': elapsedUs,
    'command': command.toJson(),
    'probe': probe.toJson(),
    'noProgressStreak': noProgressStreak,
    'previousRecordSha256': previousRecordSha256,
  };
}

class MemoryGrowthAssessment {
  MemoryGrowthAssessment({
    required this.sampleCount,
    required this.windowSampleCount,
    required this.startMedianRssBytes,
    required this.endMedianRssBytes,
    required this.positiveGrowthBytes,
    required this.peakRssBytes,
    required this.tailSlopeBytesPerAction,
    required this.tailMonotonicIncreaseRatio,
    required this.maximumPositiveGrowthBytes,
    required this.maximumTailSlopeBytesPerAction,
    required this.boundExceeded,
    required this.unboundedGrowthObserved,
  }) {
    if (sampleCount < 0 ||
        windowSampleCount < 0 ||
        windowSampleCount > sampleCount ||
        startMedianRssBytes < 0 ||
        endMedianRssBytes < 0 ||
        positiveGrowthBytes < 0 ||
        peakRssBytes < 0 ||
        maximumPositiveGrowthBytes < 0) {
      throw ArgumentError('Memory assessment counters must be non-negative.');
    }
    if (peakRssBytes < startMedianRssBytes ||
        peakRssBytes < endMedianRssBytes) {
      throw ArgumentError('Peak RSS must cover both median RSS values.');
    }
    if (!tailSlopeBytesPerAction.isFinite ||
        !tailMonotonicIncreaseRatio.isFinite ||
        tailMonotonicIncreaseRatio < 0 ||
        tailMonotonicIncreaseRatio > 1 ||
        !maximumTailSlopeBytesPerAction.isFinite ||
        maximumTailSlopeBytesPerAction < 0) {
      throw ArgumentError('Memory trend measurements are invalid.');
    }
    final observedGrowth = math.max(0, endMedianRssBytes - startMedianRssBytes);
    if (positiveGrowthBytes != observedGrowth) {
      throw ArgumentError('positiveGrowthBytes must equal the median delta.');
    }
    if (boundExceeded != (positiveGrowthBytes > maximumPositiveGrowthBytes)) {
      throw ArgumentError('boundExceeded does not match the configured bound.');
    }
    final observedUnbounded =
        boundExceeded &&
        tailSlopeBytesPerAction > maximumTailSlopeBytesPerAction &&
        tailMonotonicIncreaseRatio >= 0.75;
    if (unboundedGrowthObserved != observedUnbounded) {
      throw ArgumentError(
        'unboundedGrowthObserved does not match the bounded trend method.',
      );
    }
  }

  final int sampleCount;
  final int windowSampleCount;
  final int startMedianRssBytes;
  final int endMedianRssBytes;
  final int positiveGrowthBytes;
  final int peakRssBytes;
  final double tailSlopeBytesPerAction;
  final double tailMonotonicIncreaseRatio;
  final int maximumPositiveGrowthBytes;
  final double maximumTailSlopeBytesPerAction;
  final bool boundExceeded;
  final bool unboundedGrowthObserved;

  Map<String, Object?> toJson() => <String, Object?>{
    'sampleCount': sampleCount,
    'windowSampleCount': windowSampleCount,
    'startMedianRssBytes': startMedianRssBytes,
    'endMedianRssBytes': endMedianRssBytes,
    'positiveGrowthBytes': positiveGrowthBytes,
    'peakRssBytes': peakRssBytes,
    'tailSlopeBytesPerAction': tailSlopeBytesPerAction,
    'tailMonotonicIncreaseRatio': tailMonotonicIncreaseRatio,
    'maximumPositiveGrowthBytes': maximumPositiveGrowthBytes,
    'maximumTailSlopeBytesPerAction': maximumTailSlopeBytesPerAction,
    'boundExceeded': boundExceeded,
    'unboundedGrowthObserved': unboundedGrowthObserved,
  };
}

class EnduranceArchiveEntry {
  EnduranceArchiveEntry({
    required this.relativePath,
    required this.sha256,
    required this.byteLength,
  }) {
    if (relativePath.isEmpty ||
        relativePath.startsWith('/') ||
        relativePath.contains('..')) {
      throw ArgumentError.value(relativePath, 'relativePath');
    }
    _validateSha256(sha256, 'sha256');
    if (byteLength < 1) throw ArgumentError.value(byteLength, 'byteLength');
  }

  final String relativePath;
  final String sha256;
  final int byteLength;

  factory EnduranceArchiveEntry.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'relativePath',
      'sha256',
      'byteLength',
    }, path);
    return EnduranceArchiveEntry(
      relativePath: expectJsonString(
        json['relativePath'],
        '$path.relativePath',
      ),
      sha256: expectJsonString(json['sha256'], '$path.sha256'),
      byteLength: expectJsonInt(
        json['byteLength'],
        '$path.byteLength',
        minimum: 1,
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'relativePath': relativePath,
    'sha256': sha256,
    'byteLength': byteLength,
  };
}

class EnduranceOutcome {
  EnduranceOutcome({
    required this.enduranceRunId,
    required this.configSha256,
    required this.environmentSha256,
    required this.planSha256,
    required this.mode,
    required this.status,
    required this.componentStatus,
    required this.releaseClaimable,
    required this.startedAtUtc,
    required this.finishedAtUtc,
    required this.measurementStartedAtUtc,
    required this.measurementFinishedAtUtc,
    required this.durationMs,
    required this.actionCount,
    required this.targetReached,
    required this.evidenceComplete,
    required this.freshSetupProven,
    required this.cleanTeardownProven,
    required this.crashCount,
    required this.crossoverCount,
    required this.deadlockCount,
    required this.blockingSignalCount,
    required this.failure,
    required this.memory,
    required this.finalCorrelation,
    required this.finalRecordSha256,
    required Iterable<EnduranceArchiveEntry> inventory,
  }) : inventory = List<EnduranceArchiveEntry>.unmodifiable(inventory) {
    validateIdentifier(enduranceRunId, 'enduranceRunId');
    _validateSha256(configSha256, 'configSha256');
    _validateSha256(environmentSha256, 'environmentSha256');
    _validateSha256(planSha256, 'planSha256');
    if (releaseClaimable) {
      throw ArgumentError(
        'An endurance component result can never claim full release '
        'eligibility.',
      );
    }
    _requireUtc(startedAtUtc, 'startedAtUtc');
    _requireUtc(finishedAtUtc, 'finishedAtUtc');
    if (finishedAtUtc.isBefore(startedAtUtc)) {
      throw ArgumentError('finishedAtUtc cannot precede startedAtUtc.');
    }
    if ((measurementStartedAtUtc == null) !=
        (measurementFinishedAtUtc == null)) {
      throw ArgumentError(
        'Measurement start and finish timestamps must be both present or '
        'both absent.',
      );
    }
    if (measurementStartedAtUtc != null && measurementFinishedAtUtc != null) {
      _requireUtc(measurementStartedAtUtc!, 'measurementStartedAtUtc');
      _requireUtc(measurementFinishedAtUtc!, 'measurementFinishedAtUtc');
      if (measurementStartedAtUtc!.isBefore(startedAtUtc) ||
          measurementFinishedAtUtc!.isAfter(finishedAtUtc) ||
          measurementFinishedAtUtc!.isBefore(measurementStartedAtUtc!)) {
        throw ArgumentError(
          'The measured interval must be ordered within the harness interval.',
        );
      }
      if (measurementFinishedAtUtc!
              .difference(measurementStartedAtUtc!)
              .inMilliseconds !=
          durationMs) {
        throw ArgumentError(
          'durationMs must equal the explicit measured UTC interval.',
        );
      }
    } else if (durationMs != 0) {
      throw ArgumentError(
        'A missing measured interval requires zero measured duration.',
      );
    }
    if (durationMs < 0 || actionCount < 0) {
      throw ArgumentError('Duration and action count must be non-negative.');
    }
    for (final entry in <String, int>{
      'crashCount': crashCount,
      'crossoverCount': crossoverCount,
      'deadlockCount': deadlockCount,
      'blockingSignalCount': blockingSignalCount,
    }.entries) {
      if (entry.value < 0) throw ArgumentError.value(entry.value, entry.key);
    }
    if (inventory.isEmpty) {
      throw ArgumentError('A finalized outcome requires archive inventory.');
    }
    final paths = <String>{};
    for (final entry in inventory) {
      if (!paths.add(entry.relativePath)) {
        throw ArgumentError(
          'Duplicate archive inventory path `${entry.relativePath}`.',
        );
      }
    }
    if (finalRecordSha256 != null) {
      _validateSha256(finalRecordSha256!, 'finalRecordSha256');
    }
    if (status == EnduranceRunStatus.completed && failure != null) {
      throw ArgumentError('A completed endurance run cannot have a failure.');
    }
    if (status != EnduranceRunStatus.completed && failure == null) {
      throw ArgumentError('A non-completed endurance run requires a failure.');
    }
    final expectedOwner = switch (status) {
      EnduranceRunStatus.completed => null,
      EnduranceRunStatus.productFailure => EnduranceFailureOwner.product,
      EnduranceRunStatus.interrupted => EnduranceFailureOwner.interruption,
      EnduranceRunStatus.harnessInvalid => null,
    };
    if (expectedOwner != null && failure?.owner != expectedOwner) {
      throw ArgumentError(
        'Run status and first-causal failure owner disagree.',
      );
    }
    if (status == EnduranceRunStatus.harnessInvalid &&
        failure?.owner != EnduranceFailureOwner.harness &&
        failure?.owner != EnduranceFailureOwner.evidenceArchive) {
      throw ArgumentError(
        'harness_invalid requires harness/archive ownership.',
      );
    }
    if (componentStatus == EnduranceComponentStatus.pass &&
        (mode != EnduranceRunMode.releaseEvidence ||
            !targetReached ||
            !evidenceComplete ||
            !freshSetupProven ||
            !cleanTeardownProven ||
            status != EnduranceRunStatus.completed ||
            crashCount != 0 ||
            crossoverCount != 0 ||
            deadlockCount != 0 ||
            blockingSignalCount != 0 ||
            memory.boundExceeded ||
            memory.unboundedGrowthObserved)) {
      throw ArgumentError('Endurance component pass prerequisites are unmet.');
    }
    if (mode == EnduranceRunMode.testOnly &&
        componentStatus != EnduranceComponentStatus.unmeasured) {
      throw ArgumentError('test_only endurance runs must remain unmeasured.');
    }
  }

  final String enduranceRunId;
  final String configSha256;
  final String environmentSha256;
  final String planSha256;
  final EnduranceRunMode mode;
  final EnduranceRunStatus status;
  final EnduranceComponentStatus componentStatus;
  final bool releaseClaimable;
  final DateTime startedAtUtc;
  final DateTime finishedAtUtc;
  final DateTime? measurementStartedAtUtc;
  final DateTime? measurementFinishedAtUtc;
  final int durationMs;
  final int actionCount;
  final bool targetReached;
  final bool evidenceComplete;
  final bool freshSetupProven;
  final bool cleanTeardownProven;
  final int crashCount;
  final int crossoverCount;
  final int deadlockCount;
  final int blockingSignalCount;
  final EnduranceFailure? failure;
  final MemoryGrowthAssessment memory;
  final EnduranceCorrelation? finalCorrelation;
  final String? finalRecordSha256;
  final List<EnduranceArchiveEntry> inventory;

  factory EnduranceOutcome.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$');
    rejectUnknownKeys(json, const {
      'schemaVersion',
      'recordType',
      'enduranceRunId',
      'configSha256',
      'environmentSha256',
      'planSha256',
      'mode',
      'status',
      'componentStatus',
      'releaseClaimable',
      'startedAtUtc',
      'finishedAtUtc',
      'measurementStartedAtUtc',
      'measurementFinishedAtUtc',
      'durationMs',
      'actionCount',
      'targetReached',
      'evidenceComplete',
      'freshSetupProven',
      'cleanTeardownProven',
      'incidents',
      'failure',
      'memory',
      'finalCorrelation',
      'finalRecordSha256',
      'inventory',
    }, r'$');
    final version = expectJsonInt(json['schemaVersion'], r'$.schemaVersion');
    if (version != enduranceArchiveSchemaVersion ||
        json['recordType'] != 'outcome') {
      throw FormatException('Unsupported endurance outcome envelope.');
    }
    final incidents = expectJsonObject(json['incidents'], r'$.incidents');
    rejectUnknownKeys(incidents, const {
      'crashCount',
      'crossoverCount',
      'deadlockCount',
      'blockingSignalCount',
    }, r'$.incidents');
    final rawMemory = expectJsonObject(json['memory'], r'$.memory');
    rejectUnknownKeys(rawMemory, const {
      'sampleCount',
      'windowSampleCount',
      'startMedianRssBytes',
      'endMedianRssBytes',
      'positiveGrowthBytes',
      'peakRssBytes',
      'tailSlopeBytesPerAction',
      'tailMonotonicIncreaseRatio',
      'maximumPositiveGrowthBytes',
      'maximumTailSlopeBytesPerAction',
      'boundExceeded',
      'unboundedGrowthObserved',
    }, r'$.memory');
    double finiteDouble(String name) {
      final value = rawMemory[name];
      if (value is! num || !value.isFinite) {
        throw FormatException(
          r'$.memory.'
          '$name must be finite.',
        );
      }
      return value.toDouble();
    }

    final rawInventory = expectJsonList(json['inventory'], r'$.inventory');
    final rawFailure = json['failure'];
    final rawCorrelation = json['finalCorrelation'];
    final rawRecordSha = json['finalRecordSha256'];
    return EnduranceOutcome(
      enduranceRunId: expectJsonString(
        json['enduranceRunId'],
        r'$.enduranceRunId',
      ),
      configSha256: expectJsonString(json['configSha256'], r'$.configSha256'),
      environmentSha256: expectJsonString(
        json['environmentSha256'],
        r'$.environmentSha256',
      ),
      planSha256: expectJsonString(json['planSha256'], r'$.planSha256'),
      mode: EnduranceRunMode.parse(json['mode'], r'$.mode'),
      status: EnduranceRunStatus.parse(json['status'], r'$.status'),
      componentStatus: EnduranceComponentStatus.parse(
        json['componentStatus'],
        r'$.componentStatus',
      ),
      releaseClaimable: expectJsonBool(
        json['releaseClaimable'],
        r'$.releaseClaimable',
      ),
      startedAtUtc: _parseUtc(json['startedAtUtc'], r'$.startedAtUtc'),
      finishedAtUtc: _parseUtc(json['finishedAtUtc'], r'$.finishedAtUtc'),
      measurementStartedAtUtc: json['measurementStartedAtUtc'] == null
          ? null
          : _parseUtc(
              json['measurementStartedAtUtc'],
              r'$.measurementStartedAtUtc',
            ),
      measurementFinishedAtUtc: json['measurementFinishedAtUtc'] == null
          ? null
          : _parseUtc(
              json['measurementFinishedAtUtc'],
              r'$.measurementFinishedAtUtc',
            ),
      durationMs: expectJsonInt(
        json['durationMs'],
        r'$.durationMs',
        minimum: 0,
      ),
      actionCount: expectJsonInt(
        json['actionCount'],
        r'$.actionCount',
        minimum: 0,
      ),
      targetReached: expectJsonBool(json['targetReached'], r'$.targetReached'),
      evidenceComplete: expectJsonBool(
        json['evidenceComplete'],
        r'$.evidenceComplete',
      ),
      freshSetupProven: expectJsonBool(
        json['freshSetupProven'],
        r'$.freshSetupProven',
      ),
      cleanTeardownProven: expectJsonBool(
        json['cleanTeardownProven'],
        r'$.cleanTeardownProven',
      ),
      crashCount: expectJsonInt(
        incidents['crashCount'],
        r'$.incidents.crashCount',
        minimum: 0,
      ),
      crossoverCount: expectJsonInt(
        incidents['crossoverCount'],
        r'$.incidents.crossoverCount',
        minimum: 0,
      ),
      deadlockCount: expectJsonInt(
        incidents['deadlockCount'],
        r'$.incidents.deadlockCount',
        minimum: 0,
      ),
      blockingSignalCount: expectJsonInt(
        incidents['blockingSignalCount'],
        r'$.incidents.blockingSignalCount',
        minimum: 0,
      ),
      failure: rawFailure == null
          ? null
          : EnduranceFailure.fromJson(rawFailure, r'$.failure'),
      memory: MemoryGrowthAssessment(
        sampleCount: expectJsonInt(
          rawMemory['sampleCount'],
          r'$.memory.sampleCount',
          minimum: 0,
        ),
        windowSampleCount: expectJsonInt(
          rawMemory['windowSampleCount'],
          r'$.memory.windowSampleCount',
          minimum: 0,
        ),
        startMedianRssBytes: expectJsonInt(
          rawMemory['startMedianRssBytes'],
          r'$.memory.startMedianRssBytes',
          minimum: 0,
        ),
        endMedianRssBytes: expectJsonInt(
          rawMemory['endMedianRssBytes'],
          r'$.memory.endMedianRssBytes',
          minimum: 0,
        ),
        positiveGrowthBytes: expectJsonInt(
          rawMemory['positiveGrowthBytes'],
          r'$.memory.positiveGrowthBytes',
          minimum: 0,
        ),
        peakRssBytes: expectJsonInt(
          rawMemory['peakRssBytes'],
          r'$.memory.peakRssBytes',
          minimum: 0,
        ),
        tailSlopeBytesPerAction: finiteDouble('tailSlopeBytesPerAction'),
        tailMonotonicIncreaseRatio: finiteDouble('tailMonotonicIncreaseRatio'),
        maximumPositiveGrowthBytes: expectJsonInt(
          rawMemory['maximumPositiveGrowthBytes'],
          r'$.memory.maximumPositiveGrowthBytes',
          minimum: 0,
        ),
        maximumTailSlopeBytesPerAction: finiteDouble(
          'maximumTailSlopeBytesPerAction',
        ),
        boundExceeded: expectJsonBool(
          rawMemory['boundExceeded'],
          r'$.memory.boundExceeded',
        ),
        unboundedGrowthObserved: expectJsonBool(
          rawMemory['unboundedGrowthObserved'],
          r'$.memory.unboundedGrowthObserved',
        ),
      ),
      finalCorrelation: rawCorrelation == null
          ? null
          : EnduranceCorrelation.fromJson(
              rawCorrelation,
              r'$.finalCorrelation',
            ),
      finalRecordSha256: rawRecordSha == null
          ? null
          : expectJsonString(rawRecordSha, r'$.finalRecordSha256'),
      inventory: <EnduranceArchiveEntry>[
        for (var index = 0; index < rawInventory.length; index++)
          EnduranceArchiveEntry.fromJson(
            rawInventory[index],
            r'$.inventory['
            '$index]',
          ),
      ],
    );
  }

  Map<String, Object?> toJson() => UnmodifiableMapView(<String, Object?>{
    'schemaVersion': enduranceArchiveSchemaVersion,
    'recordType': 'outcome',
    'enduranceRunId': enduranceRunId,
    'configSha256': configSha256,
    'environmentSha256': environmentSha256,
    'planSha256': planSha256,
    'mode': mode.jsonName,
    'status': status.jsonName,
    'componentStatus': componentStatus.jsonName,
    'releaseClaimable': false,
    'startedAtUtc': startedAtUtc.toIso8601String(),
    'finishedAtUtc': finishedAtUtc.toIso8601String(),
    'measurementStartedAtUtc': measurementStartedAtUtc?.toIso8601String(),
    'measurementFinishedAtUtc': measurementFinishedAtUtc?.toIso8601String(),
    'durationMs': durationMs,
    'actionCount': actionCount,
    'targetReached': targetReached,
    'evidenceComplete': evidenceComplete,
    'freshSetupProven': freshSetupProven,
    'cleanTeardownProven': cleanTeardownProven,
    'incidents': <String, Object?>{
      'crashCount': crashCount,
      'crossoverCount': crossoverCount,
      'deadlockCount': deadlockCount,
      'blockingSignalCount': blockingSignalCount,
    },
    'failure': failure?.toJson(),
    'memory': memory.toJson(),
    'finalCorrelation': finalCorrelation?.toJson(),
    'finalRecordSha256': finalRecordSha256,
    'inventory': <Map<String, Object?>>[
      for (final entry in inventory) entry.toJson(),
    ],
  });
}

class EnduranceRunResult {
  const EnduranceRunResult({
    required this.outcome,
    required this.archiveDirectory,
    required this.archiveSha256,
  });

  final EnduranceOutcome outcome;
  final String archiveDirectory;
  final String archiveSha256;
}

void _requireNonEmpty(String value, String path) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, path, 'must not be empty');
  }
}

void _validateSha256(String value, String path) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw FormatException('$path must be a lowercase SHA-256 digest.');
  }
}

void _requireUtc(DateTime value, String path) {
  if (!value.isUtc) throw ArgumentError.value(value, path, 'must be UTC');
}

DateTime _parseUtc(Object? value, String path) {
  final text = expectJsonString(value, path);
  if (!text.endsWith('Z')) {
    throw FormatException('$path must use an explicit UTC Z timestamp.');
  }
  final result = DateTime.tryParse(text);
  if (result == null || !result.isUtc) {
    throw FormatException('$path must be a valid UTC timestamp.');
  }
  return result;
}
