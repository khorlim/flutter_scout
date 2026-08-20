import 'dart:collection';

import '../digests.dart';
import '../json_support.dart';
import '../performance/performance_config.dart';

const int enduranceConfigSchemaVersion = 1;
const int goldEnduranceDurationMs = 60 * 60 * 1000;
const int goldEnduranceActionCount = 1000;
const int goldIncrementalRssMaxBytes = 20 * 1024 * 1024;
const int maximumEnduranceDurationMs = 24 * 60 * 60 * 1000;

enum EnduranceRunMode {
  testOnly('test_only'),
  releaseEvidence('release_evidence');

  const EnduranceRunMode(this.jsonName);

  final String jsonName;

  static EnduranceRunMode parse(Object? value, String path) {
    for (final mode in values) {
      if (mode.jsonName == value) return mode;
    }
    throw FormatException(
      '$path must be one of '
      '${values.map((mode) => mode.jsonName).join(', ')}.',
    );
  }
}

class EnduranceHarnessIdentity {
  EnduranceHarnessIdentity({
    required this.controllerId,
    required this.controllerVersion,
    required this.controllerBuildSha256,
    required this.setupFixtureSha256,
    required this.teardownFixtureSha256,
  }) {
    validateIdentifier(controllerId, 'controllerId');
    _requireNonEmpty(controllerVersion, 'controllerVersion');
    _validateSha256(controllerBuildSha256, 'controllerBuildSha256');
    _validateSha256(setupFixtureSha256, 'setupFixtureSha256');
    _validateSha256(teardownFixtureSha256, 'teardownFixtureSha256');
  }

  final String controllerId;
  final String controllerVersion;
  final String controllerBuildSha256;
  final String setupFixtureSha256;
  final String teardownFixtureSha256;

  String get sha256 => jsonSha256(toJson());

  factory EnduranceHarnessIdentity.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'controllerId',
      'controllerVersion',
      'controllerBuildSha256',
      'setupFixtureSha256',
      'teardownFixtureSha256',
    }, path);
    return EnduranceHarnessIdentity(
      controllerId: expectJsonString(
        json['controllerId'],
        '$path.controllerId',
      ),
      controllerVersion: expectJsonString(
        json['controllerVersion'],
        '$path.controllerVersion',
      ),
      controllerBuildSha256: expectJsonString(
        json['controllerBuildSha256'],
        '$path.controllerBuildSha256',
      ),
      setupFixtureSha256: expectJsonString(
        json['setupFixtureSha256'],
        '$path.setupFixtureSha256',
      ),
      teardownFixtureSha256: expectJsonString(
        json['teardownFixtureSha256'],
        '$path.teardownFixtureSha256',
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'controllerId': controllerId,
    'controllerVersion': controllerVersion,
    'controllerBuildSha256': controllerBuildSha256,
    'setupFixtureSha256': setupFixtureSha256,
    'teardownFixtureSha256': teardownFixtureSha256,
  };
}

class EnduranceCollectorPin {
  EnduranceCollectorPin({
    required this.source,
    required this.method,
    required this.collectorVersion,
    required this.target,
  }) {
    for (final entry in toJson().entries) {
      _requireNonEmpty(entry.value, entry.key);
    }
  }

  final String source;
  final String method;
  final String collectorVersion;
  final String target;

  factory EnduranceCollectorPin.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'source',
      'method',
      'collectorVersion',
      'target',
    }, path);
    return EnduranceCollectorPin(
      source: expectJsonString(json['source'], '$path.source'),
      method: expectJsonString(json['method'], '$path.method'),
      collectorVersion: expectJsonString(
        json['collectorVersion'],
        '$path.collectorVersion',
      ),
      target: expectJsonString(json['target'], '$path.target'),
    );
  }

  Map<String, String> toJson() => <String, String>{
    'source': source,
    'method': method,
    'collectorVersion': collectorVersion,
    'target': target,
  };
}

class EnduranceCollectorPins {
  const EnduranceCollectorPins({
    required this.cpu,
    required this.memory,
    required this.frameTime,
  });

  final EnduranceCollectorPin cpu;
  final EnduranceCollectorPin memory;
  final EnduranceCollectorPin frameTime;

  factory EnduranceCollectorPins.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {'cpu', 'memory', 'frameTime'}, path);
    return EnduranceCollectorPins(
      cpu: EnduranceCollectorPin.fromJson(json['cpu'], '$path.cpu'),
      memory: EnduranceCollectorPin.fromJson(json['memory'], '$path.memory'),
      frameTime: EnduranceCollectorPin.fromJson(
        json['frameTime'],
        '$path.frameTime',
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'cpu': cpu.toJson(),
    'memory': memory.toJson(),
    'frameTime': frameTime.toJson(),
  };
}

class EnduranceActionSpec {
  EnduranceActionSpec({
    required this.actionId,
    required Iterable<String> arguments,
    required this.mutating,
    required this.requiresProgress,
    required this.timeoutMs,
  }) : arguments = List<String>.unmodifiable(arguments) {
    validateIdentifier(actionId, 'actionId');
    if (this.arguments.isEmpty || this.arguments.length > 64) {
      throw ArgumentError.value(
        this.arguments.length,
        'arguments',
        'must contain between 1 and 64 values',
      );
    }
    validateIdentifier(this.arguments.first, 'arguments[0]');
    for (final argument in this.arguments) {
      if (argument.isEmpty ||
          argument.length > 4096 ||
          argument.contains('\u0000')) {
        throw ArgumentError.value(
          argument,
          'arguments',
          'values must contain 1..4096 non-NUL characters',
        );
      }
      if (argument == '--app' ||
          argument.startsWith('--app=') ||
          argument == '--idempotency-key' ||
          argument.startsWith('--idempotency-key=')) {
        throw ArgumentError(
          'The runner exclusively owns `--app` and `--idempotency-key`.',
        );
      }
    }
    const forbiddenCommands = <String>{
      'attach',
      'launch',
      'ensure',
      'stop',
      'reload',
      'restart',
      'serve',
    };
    if (forbiddenCommands.contains(this.arguments.first)) {
      throw ArgumentError(
        'Endurance action `$actionId` may not replace or restart the anchored '
        'session/runtime.',
      );
    }
    if (requiresProgress && !mutating) {
      throw ArgumentError(
        'Only a mutating action may require out-of-band progress.',
      );
    }
    if (timeoutMs < 1 || timeoutMs > 10 * 60 * 1000) {
      throw ArgumentError.value(
        timeoutMs,
        'timeoutMs',
        'must be between 1 ms and 10 minutes',
      );
    }
  }

  final String actionId;
  final List<String> arguments;
  final bool mutating;
  final bool requiresProgress;
  final int timeoutMs;

  factory EnduranceActionSpec.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'actionId',
      'arguments',
      'mutating',
      'requiresProgress',
      'timeoutMs',
    }, path);
    return EnduranceActionSpec(
      actionId: expectJsonString(json['actionId'], '$path.actionId'),
      arguments: expectJsonList(json['arguments'], '$path.arguments')
          .asMap()
          .entries
          .map(
            (entry) =>
                expectJsonString(entry.value, '$path.arguments[${entry.key}]'),
          ),
      mutating: expectJsonBool(json['mutating'], '$path.mutating'),
      requiresProgress: expectJsonBool(
        json['requiresProgress'],
        '$path.requiresProgress',
      ),
      timeoutMs: expectJsonInt(
        json['timeoutMs'],
        '$path.timeoutMs',
        minimum: 1,
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'actionId': actionId,
    'arguments': arguments,
    'mutating': mutating,
    'requiresProgress': requiresProgress,
    'timeoutMs': timeoutMs,
  };
}

class EnduranceActionPlan {
  EnduranceActionPlan({
    required this.seed,
    required this.algorithm,
    required Iterable<EnduranceActionSpec> actions,
  }) : actions = List<EnduranceActionSpec>.unmodifiable(actions) {
    if (seed < 0 || seed > 0x7fffffff) {
      throw ArgumentError.value(seed, 'seed', 'must be a 31-bit integer');
    }
    if (algorithm != 'fixed_cycle_v1') {
      throw ArgumentError.value(
        algorithm,
        'algorithm',
        'only fixed_cycle_v1 is supported',
      );
    }
    if (this.actions.isEmpty || this.actions.length > 256) {
      throw ArgumentError.value(
        this.actions.length,
        'actions',
        'must contain between 1 and 256 actions',
      );
    }
    final ids = <String>{};
    for (final action in this.actions) {
      if (!ids.add(action.actionId)) {
        throw ArgumentError('Duplicate endurance action `${action.actionId}`.');
      }
    }
  }

  final int seed;
  final String algorithm;
  final List<EnduranceActionSpec> actions;

  String get sha256 => jsonSha256(toJson());

  EnduranceActionSpec actionForSequence(int sequence) {
    if (sequence < 1) {
      throw ArgumentError.value(sequence, 'sequence', 'must be positive');
    }
    return actions[(sequence - 1) % actions.length];
  }

  String idempotencyKey({
    required String enduranceRunId,
    required int sequence,
  }) {
    final digest = sha256Text('$seed:$sha256:$enduranceRunId:$sequence');
    return 'endurance-${digest.substring(0, 48)}';
  }

  factory EnduranceActionPlan.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {'seed', 'algorithm', 'actions'}, path);
    final rawActions = expectJsonList(json['actions'], '$path.actions');
    return EnduranceActionPlan(
      seed: expectJsonInt(json['seed'], '$path.seed', minimum: 0),
      algorithm: expectJsonString(json['algorithm'], '$path.algorithm'),
      actions: <EnduranceActionSpec>[
        for (var index = 0; index < rawActions.length; index++)
          EnduranceActionSpec.fromJson(
            rawActions[index],
            '$path.actions[$index]',
          ),
      ],
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'seed': seed,
    'algorithm': algorithm,
    'actions': <Map<String, Object?>>[
      for (final action in actions) action.toJson(),
    ],
  };
}

class EnduranceLimits {
  EnduranceLimits({
    required this.minimumDurationMs,
    required this.minimumActions,
    required this.maximumDurationMs,
    required this.maximumActions,
    required this.maximumConsecutiveNoProgress,
    required this.maximumPositiveRssGrowthBytes,
    required this.maximumTailSlopeBytesPerAction,
    required this.memoryWindowSamples,
    required this.harnessHookTimeoutMs,
    required this.maximumCommandOutputBytes,
    required this.maximumArchiveBytes,
  }) {
    if (minimumDurationMs < 0 || minimumActions < 0) {
      throw ArgumentError('Minimum duration/actions must be non-negative.');
    }
    if (minimumDurationMs == 0 && minimumActions == 0) {
      throw ArgumentError('At least one endurance target must be positive.');
    }
    if (maximumDurationMs < 1 ||
        maximumDurationMs < minimumDurationMs ||
        maximumDurationMs > maximumEnduranceDurationMs) {
      throw ArgumentError(
        'maximumDurationMs must cover minimumDurationMs and be at most '
        '24 hours.',
      );
    }
    if (maximumActions < 1 ||
        maximumActions < minimumActions ||
        maximumActions > 1000000) {
      throw ArgumentError(
        'maximumActions must cover minimumActions and be at most 1,000,000.',
      );
    }
    if (maximumConsecutiveNoProgress < 1 ||
        maximumConsecutiveNoProgress > 1000) {
      throw ArgumentError.value(
        maximumConsecutiveNoProgress,
        'maximumConsecutiveNoProgress',
      );
    }
    if (maximumPositiveRssGrowthBytes < 0) {
      throw ArgumentError.value(
        maximumPositiveRssGrowthBytes,
        'maximumPositiveRssGrowthBytes',
      );
    }
    if (!maximumTailSlopeBytesPerAction.isFinite ||
        maximumTailSlopeBytesPerAction < 0) {
      throw ArgumentError.value(
        maximumTailSlopeBytesPerAction,
        'maximumTailSlopeBytesPerAction',
      );
    }
    if (memoryWindowSamples < 3 || memoryWindowSamples > 512) {
      throw ArgumentError.value(
        memoryWindowSamples,
        'memoryWindowSamples',
        'must be between 3 and 512',
      );
    }
    if (harnessHookTimeoutMs < 1 || harnessHookTimeoutMs > 10 * 60 * 1000) {
      throw ArgumentError.value(harnessHookTimeoutMs, 'harnessHookTimeoutMs');
    }
    if (maximumCommandOutputBytes < 1024 ||
        maximumCommandOutputBytes > 4 * 1024 * 1024) {
      throw ArgumentError.value(
        maximumCommandOutputBytes,
        'maximumCommandOutputBytes',
        'must be between 1 KiB and 4 MiB',
      );
    }
    if (maximumArchiveBytes < 1024 * 1024 ||
        maximumArchiveBytes > 4 * 1024 * 1024 * 1024) {
      throw ArgumentError.value(
        maximumArchiveBytes,
        'maximumArchiveBytes',
        'must be between 1 MiB and 4 GiB',
      );
    }
  }

  final int minimumDurationMs;
  final int minimumActions;
  final int maximumDurationMs;
  final int maximumActions;
  final int maximumConsecutiveNoProgress;
  final int maximumPositiveRssGrowthBytes;
  final double maximumTailSlopeBytesPerAction;
  final int memoryWindowSamples;
  final int harnessHookTimeoutMs;
  final int maximumCommandOutputBytes;
  final int maximumArchiveBytes;

  bool targetReached({required int durationMs, required int actionCount}) =>
      (minimumDurationMs > 0 && durationMs >= minimumDurationMs) ||
      (minimumActions > 0 && actionCount >= minimumActions);

  factory EnduranceLimits.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'minimumDurationMs',
      'minimumActions',
      'maximumDurationMs',
      'maximumActions',
      'maximumConsecutiveNoProgress',
      'maximumPositiveRssGrowthBytes',
      'maximumTailSlopeBytesPerAction',
      'memoryWindowSamples',
      'harnessHookTimeoutMs',
      'maximumCommandOutputBytes',
      'maximumArchiveBytes',
    }, path);
    final slope = json['maximumTailSlopeBytesPerAction'];
    if (slope is! num || !slope.isFinite || slope < 0) {
      throw FormatException(
        '$path.maximumTailSlopeBytesPerAction must be finite and non-negative.',
      );
    }
    return EnduranceLimits(
      minimumDurationMs: expectJsonInt(
        json['minimumDurationMs'],
        '$path.minimumDurationMs',
        minimum: 0,
      ),
      minimumActions: expectJsonInt(
        json['minimumActions'],
        '$path.minimumActions',
        minimum: 0,
      ),
      maximumDurationMs: expectJsonInt(
        json['maximumDurationMs'],
        '$path.maximumDurationMs',
        minimum: 1,
      ),
      maximumActions: expectJsonInt(
        json['maximumActions'],
        '$path.maximumActions',
        minimum: 1,
      ),
      maximumConsecutiveNoProgress: expectJsonInt(
        json['maximumConsecutiveNoProgress'],
        '$path.maximumConsecutiveNoProgress',
        minimum: 1,
      ),
      maximumPositiveRssGrowthBytes: expectJsonInt(
        json['maximumPositiveRssGrowthBytes'],
        '$path.maximumPositiveRssGrowthBytes',
        minimum: 0,
      ),
      maximumTailSlopeBytesPerAction: slope.toDouble(),
      memoryWindowSamples: expectJsonInt(
        json['memoryWindowSamples'],
        '$path.memoryWindowSamples',
        minimum: 3,
      ),
      harnessHookTimeoutMs: expectJsonInt(
        json['harnessHookTimeoutMs'],
        '$path.harnessHookTimeoutMs',
        minimum: 1,
      ),
      maximumCommandOutputBytes: expectJsonInt(
        json['maximumCommandOutputBytes'],
        '$path.maximumCommandOutputBytes',
        minimum: 1024,
      ),
      maximumArchiveBytes: expectJsonInt(
        json['maximumArchiveBytes'],
        '$path.maximumArchiveBytes',
        minimum: 1024 * 1024,
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'minimumDurationMs': minimumDurationMs,
    'minimumActions': minimumActions,
    'maximumDurationMs': maximumDurationMs,
    'maximumActions': maximumActions,
    'maximumConsecutiveNoProgress': maximumConsecutiveNoProgress,
    'maximumPositiveRssGrowthBytes': maximumPositiveRssGrowthBytes,
    'maximumTailSlopeBytesPerAction': maximumTailSlopeBytesPerAction,
    'memoryWindowSamples': memoryWindowSamples,
    'harnessHookTimeoutMs': harnessHookTimeoutMs,
    'maximumCommandOutputBytes': maximumCommandOutputBytes,
    'maximumArchiveBytes': maximumArchiveBytes,
  };
}

class EnduranceConfig {
  EnduranceConfig({
    required this.enduranceRunId,
    required this.mode,
    required this.testOnlyReason,
    required this.condition,
    required this.environment,
    required this.sessionName,
    required this.harness,
    required this.collectors,
    required this.plan,
    required this.limits,
  }) {
    validateIdentifier(enduranceRunId, 'enduranceRunId');
    validateIdentifier(sessionName, 'sessionName');
    if (environment.buildMode != PerformanceBuildMode.debug) {
      throw ArgumentError(
        'Endurance evaluation requires an active debug Scout build.',
      );
    }
    if (mode == EnduranceRunMode.testOnly) {
      if (testOnlyReason == null || testOnlyReason!.trim().isEmpty) {
        throw ArgumentError('test_only configs require testOnlyReason.');
      }
    } else {
      if (testOnlyReason != null) {
        throw ArgumentError(
          'release_evidence configs must not include testOnlyReason.',
        );
      }
      final durationEligible =
          limits.minimumDurationMs >= goldEnduranceDurationMs;
      final actionEligible = limits.minimumActions >= goldEnduranceActionCount;
      if (!durationEligible && !actionEligible) {
        throw ArgumentError(
          'release_evidence must preregister at least 60 minutes or 1,000 '
          'actions.',
        );
      }
      if (limits.maximumPositiveRssGrowthBytes > goldIncrementalRssMaxBytes) {
        throw ArgumentError(
          'release_evidence may not weaken the 20 MiB incremental RSS gate.',
        );
      }
    }
  }

  final String enduranceRunId;
  final EnduranceRunMode mode;
  final String? testOnlyReason;
  final PerformanceCondition condition;
  final PerformanceEnvironment environment;
  final String sessionName;
  final EnduranceHarnessIdentity harness;
  final EnduranceCollectorPins collectors;
  final EnduranceActionPlan plan;
  final EnduranceLimits limits;

  String get sha256 => jsonSha256(toJson());

  factory EnduranceConfig.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$');
    rejectUnknownKeys(json, const {
      'schemaVersion',
      'enduranceRunId',
      'mode',
      'testOnlyReason',
      'condition',
      'environment',
      'sessionName',
      'harness',
      'collectors',
      'plan',
      'limits',
    }, r'$');
    final version = expectJsonInt(json['schemaVersion'], r'$.schemaVersion');
    if (version != enduranceConfigSchemaVersion) {
      throw FormatException(
        'Unsupported endurance config schemaVersion $version; expected '
        '$enduranceConfigSchemaVersion.',
      );
    }
    final testOnlyReason = json['testOnlyReason'];
    return EnduranceConfig(
      enduranceRunId: expectJsonString(
        json['enduranceRunId'],
        r'$.enduranceRunId',
      ),
      mode: EnduranceRunMode.parse(json['mode'], r'$.mode'),
      testOnlyReason: testOnlyReason == null
          ? null
          : expectJsonString(testOnlyReason, r'$.testOnlyReason'),
      condition: PerformanceCondition.fromJson(
        json['condition'],
        r'$.condition',
      ),
      environment: PerformanceEnvironment.fromJson(
        json['environment'],
        r'$.environment',
      ),
      sessionName: expectJsonString(json['sessionName'], r'$.sessionName'),
      harness: EnduranceHarnessIdentity.fromJson(json['harness'], r'$.harness'),
      collectors: EnduranceCollectorPins.fromJson(
        json['collectors'],
        r'$.collectors',
      ),
      plan: EnduranceActionPlan.fromJson(json['plan'], r'$.plan'),
      limits: EnduranceLimits.fromJson(json['limits'], r'$.limits'),
    );
  }

  Map<String, Object?> toJson() => UnmodifiableMapView(<String, Object?>{
    'schemaVersion': enduranceConfigSchemaVersion,
    'enduranceRunId': enduranceRunId,
    'mode': mode.jsonName,
    'testOnlyReason': testOnlyReason,
    'condition': condition.toJson(),
    'environment': environment.toJson(),
    'sessionName': sessionName,
    'harness': harness.toJson(),
    'collectors': collectors.toJson(),
    'plan': plan.toJson(),
    'limits': limits.toJson(),
  });
}

void _validateSha256(String value, String path) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw FormatException('$path must be a lowercase SHA-256 digest.');
  }
}

void _requireNonEmpty(String value, String path) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, path, 'must not be empty');
  }
}
