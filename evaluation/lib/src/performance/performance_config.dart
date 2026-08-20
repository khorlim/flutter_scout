import '../digests.dart';
import '../json_support.dart';

const int performanceConfigSchemaVersion = 1;

enum PerformanceBuildMode {
  debug('debug'),
  profile('profile'),
  release('release');

  const PerformanceBuildMode(this.jsonName);

  final String jsonName;

  static PerformanceBuildMode parse(Object? value, String path) {
    for (final mode in values) {
      if (value == mode.jsonName) return mode;
    }
    throw FormatException(
      '$path must be one of ${values.map((item) => item.jsonName).join(', ')}.',
    );
  }
}

enum ThresholdRatificationStatus {
  provisional('provisional'),
  ratified('ratified');

  const ThresholdRatificationStatus(this.jsonName);

  final String jsonName;

  static ThresholdRatificationStatus parse(Object? value, String path) {
    for (final status in values) {
      if (value == status.jsonName) return status;
    }
    throw FormatException('$path must be `provisional` or `ratified`.');
  }
}

enum PerformanceScenario {
  warmBriefInspectStandard('warm_brief_inspect_standard'),
  warmBriefInspectLargeTree('warm_brief_inspect_large_tree'),
  actionOverhead('action_overhead');

  const PerformanceScenario(this.jsonName);

  final String jsonName;

  static PerformanceScenario parse(Object? value, String path) {
    for (final scenario in values) {
      if (value == scenario.jsonName) return scenario;
    }
    throw FormatException(
      '$path must be one of '
      '${values.map((item) => item.jsonName).join(', ')}.',
    );
  }
}

class PerformanceCondition {
  PerformanceCondition({
    required this.conditionId,
    required this.scoutGitCommit,
    required this.cliVersion,
    required this.helperVersion,
    required this.protocolVersion,
  }) {
    validateIdentifier(conditionId, 'conditionId');
    _validateGitCommit(scoutGitCommit, 'scoutGitCommit');
    _requireNonEmpty({
      'cliVersion': cliVersion,
      'helperVersion': helperVersion,
      'protocolVersion': protocolVersion,
    });
  }

  final String conditionId;
  final String scoutGitCommit;
  final String cliVersion;
  final String helperVersion;
  final String protocolVersion;

  factory PerformanceCondition.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'conditionId',
      'scoutGitCommit',
      'cliVersion',
      'helperVersion',
      'protocolVersion',
    }, path);
    return PerformanceCondition(
      conditionId: expectJsonString(json['conditionId'], '$path.conditionId'),
      scoutGitCommit: expectJsonString(
        json['scoutGitCommit'],
        '$path.scoutGitCommit',
      ),
      cliVersion: expectJsonString(json['cliVersion'], '$path.cliVersion'),
      helperVersion: expectJsonString(
        json['helperVersion'],
        '$path.helperVersion',
      ),
      protocolVersion: expectJsonString(
        json['protocolVersion'],
        '$path.protocolVersion',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'conditionId': conditionId,
    'scoutGitCommit': scoutGitCommit,
    'cliVersion': cliVersion,
    'helperVersion': helperVersion,
    'protocolVersion': protocolVersion,
  };
}

class PerformanceHardware {
  PerformanceHardware({
    required this.model,
    required this.cpu,
    required this.memoryBytes,
  }) {
    _requireNonEmpty({'model': model, 'cpu': cpu});
    if (memoryBytes < 1) {
      throw ArgumentError.value(memoryBytes, 'memoryBytes', 'must be positive');
    }
  }

  final String model;
  final String cpu;
  final int memoryBytes;

  factory PerformanceHardware.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {'model', 'cpu', 'memoryBytes'}, path);
    return PerformanceHardware(
      model: expectJsonString(json['model'], '$path.model'),
      cpu: expectJsonString(json['cpu'], '$path.cpu'),
      memoryBytes: expectJsonInt(
        json['memoryBytes'],
        '$path.memoryBytes',
        minimum: 1,
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'model': model,
    'cpu': cpu,
    'memoryBytes': memoryBytes,
  };
}

class PerformanceHostOs {
  PerformanceHostOs({
    required this.name,
    required this.version,
    required this.architecture,
  }) {
    _requireNonEmpty({
      'name': name,
      'version': version,
      'architecture': architecture,
    });
  }

  final String name;
  final String version;
  final String architecture;

  factory PerformanceHostOs.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {'name', 'version', 'architecture'}, path);
    return PerformanceHostOs(
      name: expectJsonString(json['name'], '$path.name'),
      version: expectJsonString(json['version'], '$path.version'),
      architecture: expectJsonString(
        json['architecture'],
        '$path.architecture',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'version': version,
    'architecture': architecture,
  };
}

class PerformanceToolchains {
  PerformanceToolchains({
    required this.flutterVersion,
    required this.dartVersion,
    required this.platformSdkVersion,
  }) {
    _requireNonEmpty({
      'flutterVersion': flutterVersion,
      'dartVersion': dartVersion,
      'platformSdkVersion': platformSdkVersion,
    });
  }

  final String flutterVersion;
  final String dartVersion;
  final String platformSdkVersion;

  factory PerformanceToolchains.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'flutterVersion',
      'dartVersion',
      'platformSdkVersion',
    }, path);
    return PerformanceToolchains(
      flutterVersion: expectJsonString(
        json['flutterVersion'],
        '$path.flutterVersion',
      ),
      dartVersion: expectJsonString(json['dartVersion'], '$path.dartVersion'),
      platformSdkVersion: expectJsonString(
        json['platformSdkVersion'],
        '$path.platformSdkVersion',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'flutterVersion': flutterVersion,
    'dartVersion': dartVersion,
    'platformSdkVersion': platformSdkVersion,
  };
}

class PerformanceFixture {
  PerformanceFixture({
    required this.appId,
    required this.appGitCommit,
    required this.fixtureId,
    required this.scenario,
    required this.treeSizeNodes,
  }) {
    validateIdentifier(appId, 'appId');
    validateIdentifier(fixtureId, 'fixtureId');
    _validateGitCommit(appGitCommit, 'appGitCommit');
    if (treeSizeNodes < 1) {
      throw ArgumentError.value(
        treeSizeNodes,
        'treeSizeNodes',
        'must be positive',
      );
    }
  }

  final String appId;
  final String appGitCommit;
  final String fixtureId;
  final PerformanceScenario scenario;
  final int treeSizeNodes;

  factory PerformanceFixture.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'appId',
      'appGitCommit',
      'fixtureId',
      'scenario',
      'treeSizeNodes',
    }, path);
    return PerformanceFixture(
      appId: expectJsonString(json['appId'], '$path.appId'),
      appGitCommit: expectJsonString(
        json['appGitCommit'],
        '$path.appGitCommit',
      ),
      fixtureId: expectJsonString(json['fixtureId'], '$path.fixtureId'),
      scenario: PerformanceScenario.parse(json['scenario'], '$path.scenario'),
      treeSizeNodes: expectJsonInt(
        json['treeSizeNodes'],
        '$path.treeSizeNodes',
        minimum: 1,
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'appId': appId,
    'appGitCommit': appGitCommit,
    'fixtureId': fixtureId,
    'scenario': scenario.jsonName,
    'treeSizeNodes': treeSizeNodes,
  };
}

class PerformanceViewport {
  PerformanceViewport({
    required this.logicalWidth,
    required this.logicalHeight,
    required this.devicePixelRatio,
  }) {
    _validateFinitePositive(logicalWidth, 'logicalWidth');
    _validateFinitePositive(logicalHeight, 'logicalHeight');
    _validateFinitePositive(devicePixelRatio, 'devicePixelRatio');
  }

  final double logicalWidth;
  final double logicalHeight;
  final double devicePixelRatio;

  factory PerformanceViewport.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'logicalWidth',
      'logicalHeight',
      'devicePixelRatio',
    }, path);
    return PerformanceViewport(
      logicalWidth: _expectFinitePositive(
        json['logicalWidth'],
        '$path.logicalWidth',
      ),
      logicalHeight: _expectFinitePositive(
        json['logicalHeight'],
        '$path.logicalHeight',
      ),
      devicePixelRatio: _expectFinitePositive(
        json['devicePixelRatio'],
        '$path.devicePixelRatio',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'logicalWidth': logicalWidth,
    'logicalHeight': logicalHeight,
    'devicePixelRatio': devicePixelRatio,
  };
}

class PerformanceDevice {
  PerformanceDevice({
    required this.platform,
    required this.model,
    required this.osImage,
  }) {
    _requireNonEmpty({
      'platform': platform,
      'model': model,
      'osImage': osImage,
    });
  }

  final String platform;
  final String model;
  final String osImage;

  factory PerformanceDevice.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {'platform', 'model', 'osImage'}, path);
    return PerformanceDevice(
      platform: expectJsonString(json['platform'], '$path.platform'),
      model: expectJsonString(json['model'], '$path.model'),
      osImage: expectJsonString(json['osImage'], '$path.osImage'),
    );
  }

  Map<String, Object?> toJson() => {
    'platform': platform,
    'model': model,
    'osImage': osImage,
  };
}

class PerformanceMeasurementMethod {
  PerformanceMeasurementMethod({
    required this.clock,
    required this.method,
    required this.collector,
    required this.collectorVersion,
    required this.tokenEstimator,
    required this.estimatedUtf8BytesPerToken,
  }) {
    _requireNonEmpty({
      'clock': clock,
      'method': method,
      'collector': collector,
      'collectorVersion': collectorVersion,
    });
    if (tokenEstimator != 'utf8_bytes_divisor_ceiling') {
      throw ArgumentError.value(
        tokenEstimator,
        'tokenEstimator',
        'only utf8_bytes_divisor_ceiling is supported',
      );
    }
    _validateFinitePositive(
      estimatedUtf8BytesPerToken,
      'estimatedUtf8BytesPerToken',
    );
  }

  final String clock;
  final String method;
  final String collector;
  final String collectorVersion;
  final String tokenEstimator;
  final double estimatedUtf8BytesPerToken;

  factory PerformanceMeasurementMethod.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'clock',
      'method',
      'collector',
      'collectorVersion',
      'tokenEstimator',
      'estimatedUtf8BytesPerToken',
    }, path);
    return PerformanceMeasurementMethod(
      clock: expectJsonString(json['clock'], '$path.clock'),
      method: expectJsonString(json['method'], '$path.method'),
      collector: expectJsonString(json['collector'], '$path.collector'),
      collectorVersion: expectJsonString(
        json['collectorVersion'],
        '$path.collectorVersion',
      ),
      tokenEstimator: expectJsonString(
        json['tokenEstimator'],
        '$path.tokenEstimator',
      ),
      estimatedUtf8BytesPerToken: _expectFinitePositive(
        json['estimatedUtf8BytesPerToken'],
        '$path.estimatedUtf8BytesPerToken',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'clock': clock,
    'method': method,
    'collector': collector,
    'collectorVersion': collectorVersion,
    'tokenEstimator': tokenEstimator,
    'estimatedUtf8BytesPerToken': estimatedUtf8BytesPerToken,
  };
}

class PerformanceEnvironment {
  const PerformanceEnvironment({
    required this.hardware,
    required this.hostOs,
    required this.toolchains,
    required this.buildMode,
    required this.fixture,
    required this.viewport,
    required this.device,
    required this.measurement,
  });

  final PerformanceHardware hardware;
  final PerformanceHostOs hostOs;
  final PerformanceToolchains toolchains;
  final PerformanceBuildMode buildMode;
  final PerformanceFixture fixture;
  final PerformanceViewport viewport;
  final PerformanceDevice device;
  final PerformanceMeasurementMethod measurement;

  String get sha256 => jsonSha256(toJson());

  factory PerformanceEnvironment.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'hardware',
      'hostOs',
      'toolchains',
      'buildMode',
      'fixture',
      'viewport',
      'device',
      'measurement',
    }, path);
    return PerformanceEnvironment(
      hardware: PerformanceHardware.fromJson(
        json['hardware'],
        '$path.hardware',
      ),
      hostOs: PerformanceHostOs.fromJson(json['hostOs'], '$path.hostOs'),
      toolchains: PerformanceToolchains.fromJson(
        json['toolchains'],
        '$path.toolchains',
      ),
      buildMode: PerformanceBuildMode.parse(
        json['buildMode'],
        '$path.buildMode',
      ),
      fixture: PerformanceFixture.fromJson(json['fixture'], '$path.fixture'),
      viewport: PerformanceViewport.fromJson(
        json['viewport'],
        '$path.viewport',
      ),
      device: PerformanceDevice.fromJson(json['device'], '$path.device'),
      measurement: PerformanceMeasurementMethod.fromJson(
        json['measurement'],
        '$path.measurement',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'hardware': hardware.toJson(),
    'hostOs': hostOs.toJson(),
    'toolchains': toolchains.toJson(),
    'buildMode': buildMode.jsonName,
    'fixture': fixture.toJson(),
    'viewport': viewport.toJson(),
    'device': device.toJson(),
    'measurement': measurement.toJson(),
  };
}

class PerformanceThresholds {
  PerformanceThresholds({
    required this.status,
    required this.ratificationId,
    required this.frozenEnvironmentSha256,
    required this.warmBriefInspectStandardP95Us,
    required this.warmBriefInspectLargeTreeP95Us,
    required this.actionOverheadP95Us,
    required this.payloadP95EstimatedTokens,
    required this.idleCpuMaxPercent,
    required this.incrementalRssMaxBytes,
    required this.frameTimeMedianRegressionMaxPercent,
    required this.enduranceMinDurationMs,
    required this.enduranceMinActions,
    required this.enduranceMaxGrowthBytes,
    required this.comparisonTolerancePercent,
  }) {
    _validateNonNegativeInt(
      warmBriefInspectStandardP95Us,
      'warmBriefInspectStandardP95Us',
    );
    _validateNonNegativeInt(
      warmBriefInspectLargeTreeP95Us,
      'warmBriefInspectLargeTreeP95Us',
    );
    _validateNonNegativeInt(actionOverheadP95Us, 'actionOverheadP95Us');
    _validateNonNegativeInt(
      payloadP95EstimatedTokens,
      'payloadP95EstimatedTokens',
    );
    _validateFiniteNonNegative(idleCpuMaxPercent, 'idleCpuMaxPercent');
    _validateNonNegativeInt(incrementalRssMaxBytes, 'incrementalRssMaxBytes');
    _validateFiniteNonNegative(
      frameTimeMedianRegressionMaxPercent,
      'frameTimeMedianRegressionMaxPercent',
    );
    _validateNonNegativeInt(enduranceMinDurationMs, 'enduranceMinDurationMs');
    _validateNonNegativeInt(enduranceMinActions, 'enduranceMinActions');
    _validateNonNegativeInt(enduranceMaxGrowthBytes, 'enduranceMaxGrowthBytes');
    _validateFiniteNonNegative(
      comparisonTolerancePercent,
      'comparisonTolerancePercent',
    );
    if (warmBriefInspectStandardP95Us > 300000 ||
        warmBriefInspectLargeTreeP95Us > 750000 ||
        actionOverheadP95Us > 250000 ||
        payloadP95EstimatedTokens > 1500 ||
        idleCpuMaxPercent > 1 ||
        incrementalRssMaxBytes > 20 * 1024 * 1024 ||
        frameTimeMedianRegressionMaxPercent > 5 ||
        enduranceMinDurationMs < 60 * 60 * 1000 ||
        enduranceMinActions < 1000 ||
        comparisonTolerancePercent > 5) {
      throw ArgumentError(
        'Performance thresholds may be stricter than QUALITY_STANDARD §14.2 '
        'but must not weaken its provisional gold targets.',
      );
    }
    if (status == ThresholdRatificationStatus.ratified) {
      if (ratificationId == null || ratificationId!.trim().isEmpty) {
        throw ArgumentError(
          'Ratified thresholds require a non-empty ratificationId.',
        );
      }
      if (frozenEnvironmentSha256 == null) {
        throw ArgumentError(
          'Ratified thresholds require frozenEnvironmentSha256.',
        );
      }
      _validateSha256(frozenEnvironmentSha256!, 'frozenEnvironmentSha256');
    } else if (ratificationId != null || frozenEnvironmentSha256 != null) {
      throw ArgumentError(
        'Provisional thresholds must not carry ratification evidence.',
      );
    }
  }

  final ThresholdRatificationStatus status;
  final String? ratificationId;
  final String? frozenEnvironmentSha256;
  final int warmBriefInspectStandardP95Us;
  final int warmBriefInspectLargeTreeP95Us;
  final int actionOverheadP95Us;
  final int payloadP95EstimatedTokens;
  final double idleCpuMaxPercent;
  final int incrementalRssMaxBytes;
  final double frameTimeMedianRegressionMaxPercent;
  final int enduranceMinDurationMs;
  final int enduranceMinActions;
  final int enduranceMaxGrowthBytes;
  final double comparisonTolerancePercent;

  factory PerformanceThresholds.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'status',
      'ratificationId',
      'frozenEnvironmentSha256',
      'warmBriefInspectStandardP95Us',
      'warmBriefInspectLargeTreeP95Us',
      'actionOverheadP95Us',
      'payloadP95EstimatedTokens',
      'idleCpuMaxPercent',
      'incrementalRssMaxBytes',
      'frameTimeMedianRegressionMaxPercent',
      'enduranceMinDurationMs',
      'enduranceMinActions',
      'enduranceMaxGrowthBytes',
      'comparisonTolerancePercent',
    }, path);
    return PerformanceThresholds(
      status: ThresholdRatificationStatus.parse(json['status'], '$path.status'),
      ratificationId: _expectNullableString(
        json['ratificationId'],
        '$path.ratificationId',
      ),
      frozenEnvironmentSha256: _expectNullableString(
        json['frozenEnvironmentSha256'],
        '$path.frozenEnvironmentSha256',
      ),
      warmBriefInspectStandardP95Us: expectJsonInt(
        json['warmBriefInspectStandardP95Us'],
        '$path.warmBriefInspectStandardP95Us',
        minimum: 0,
      ),
      warmBriefInspectLargeTreeP95Us: expectJsonInt(
        json['warmBriefInspectLargeTreeP95Us'],
        '$path.warmBriefInspectLargeTreeP95Us',
        minimum: 0,
      ),
      actionOverheadP95Us: expectJsonInt(
        json['actionOverheadP95Us'],
        '$path.actionOverheadP95Us',
        minimum: 0,
      ),
      payloadP95EstimatedTokens: expectJsonInt(
        json['payloadP95EstimatedTokens'],
        '$path.payloadP95EstimatedTokens',
        minimum: 0,
      ),
      idleCpuMaxPercent: _expectFiniteNonNegative(
        json['idleCpuMaxPercent'],
        '$path.idleCpuMaxPercent',
      ),
      incrementalRssMaxBytes: expectJsonInt(
        json['incrementalRssMaxBytes'],
        '$path.incrementalRssMaxBytes',
        minimum: 0,
      ),
      frameTimeMedianRegressionMaxPercent: _expectFiniteNonNegative(
        json['frameTimeMedianRegressionMaxPercent'],
        '$path.frameTimeMedianRegressionMaxPercent',
      ),
      enduranceMinDurationMs: expectJsonInt(
        json['enduranceMinDurationMs'],
        '$path.enduranceMinDurationMs',
        minimum: 0,
      ),
      enduranceMinActions: expectJsonInt(
        json['enduranceMinActions'],
        '$path.enduranceMinActions',
        minimum: 0,
      ),
      enduranceMaxGrowthBytes: expectJsonInt(
        json['enduranceMaxGrowthBytes'],
        '$path.enduranceMaxGrowthBytes',
        minimum: 0,
      ),
      comparisonTolerancePercent: _expectFiniteNonNegative(
        json['comparisonTolerancePercent'],
        '$path.comparisonTolerancePercent',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'status': status.jsonName,
    'ratificationId': ratificationId,
    'frozenEnvironmentSha256': frozenEnvironmentSha256,
    'warmBriefInspectStandardP95Us': warmBriefInspectStandardP95Us,
    'warmBriefInspectLargeTreeP95Us': warmBriefInspectLargeTreeP95Us,
    'actionOverheadP95Us': actionOverheadP95Us,
    'payloadP95EstimatedTokens': payloadP95EstimatedTokens,
    'idleCpuMaxPercent': idleCpuMaxPercent,
    'incrementalRssMaxBytes': incrementalRssMaxBytes,
    'frameTimeMedianRegressionMaxPercent': frameTimeMedianRegressionMaxPercent,
    'enduranceMinDurationMs': enduranceMinDurationMs,
    'enduranceMinActions': enduranceMinActions,
    'enduranceMaxGrowthBytes': enduranceMaxGrowthBytes,
    'comparisonTolerancePercent': comparisonTolerancePercent,
  };
}

class PerformanceConfig {
  PerformanceConfig({
    required this.benchmarkId,
    required this.baseline,
    required this.candidate,
    required this.environment,
    required this.warmupIterations,
    required this.repetitions,
    required this.thresholds,
  }) {
    validateIdentifier(benchmarkId, 'benchmarkId');
    if (baseline.conditionId == candidate.conditionId) {
      throw ArgumentError('Baseline and candidate condition ids must differ.');
    }
    if (baseline.scoutGitCommit == candidate.scoutGitCommit) {
      throw ArgumentError('Baseline and candidate commits must differ.');
    }
    if (environment.buildMode != PerformanceBuildMode.debug) {
      throw ArgumentError(
        'Active Scout performance scenarios require a debug app. Scout must '
        'remain inactive in profile and release builds.',
      );
    }
    if (warmupIterations < 1) {
      throw ArgumentError.value(
        warmupIterations,
        'warmupIterations',
        'must be positive',
      );
    }
    if (repetitions < 2) {
      throw ArgumentError.value(
        repetitions,
        'repetitions',
        'must be at least two',
      );
    }
    if (thresholds.status == ThresholdRatificationStatus.ratified &&
        repetitions < 100) {
      throw ArgumentError.value(
        repetitions,
        'repetitions',
        'ratified primitive evidence requires at least 100 repetitions per '
            'condition',
      );
    }
    if (thresholds.status == ThresholdRatificationStatus.ratified &&
        thresholds.frozenEnvironmentSha256 != environment.sha256) {
      throw ArgumentError(
        'Ratified thresholds are pinned to '
        '`${thresholds.frozenEnvironmentSha256}`, but this environment is '
        '`${environment.sha256}`.',
      );
    }
  }

  final String benchmarkId;
  final PerformanceCondition baseline;
  final PerformanceCondition candidate;
  final PerformanceEnvironment environment;
  final int warmupIterations;
  final int repetitions;
  final PerformanceThresholds thresholds;

  List<PerformanceCondition> get conditions => [baseline, candidate];

  String get sha256 => jsonSha256(toJson());

  Set<String> get expectedSampleIds => {
    for (final condition in conditions)
      for (var repetition = 1; repetition <= repetitions; repetition++)
        performanceSampleId(condition.conditionId, repetition),
  };

  factory PerformanceConfig.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$');
    rejectUnknownKeys(json, const {
      'schemaVersion',
      'benchmarkId',
      'conditions',
      'environment',
      'warmupIterations',
      'repetitions',
      'thresholds',
    }, r'$');
    final schemaVersion = expectJsonInt(
      json['schemaVersion'],
      r'$.schemaVersion',
    );
    if (schemaVersion != performanceConfigSchemaVersion) {
      throw FormatException(
        'Unsupported performance config schemaVersion $schemaVersion; '
        'expected $performanceConfigSchemaVersion.',
      );
    }
    final conditions = expectJsonObject(json['conditions'], r'$.conditions');
    rejectUnknownKeys(conditions, const {
      'baseline',
      'candidate',
    }, r'$.conditions');
    return PerformanceConfig(
      benchmarkId: expectJsonString(json['benchmarkId'], r'$.benchmarkId'),
      baseline: PerformanceCondition.fromJson(
        conditions['baseline'],
        r'$.conditions.baseline',
      ),
      candidate: PerformanceCondition.fromJson(
        conditions['candidate'],
        r'$.conditions.candidate',
      ),
      environment: PerformanceEnvironment.fromJson(
        json['environment'],
        r'$.environment',
      ),
      warmupIterations: expectJsonInt(
        json['warmupIterations'],
        r'$.warmupIterations',
        minimum: 1,
      ),
      repetitions: expectJsonInt(
        json['repetitions'],
        r'$.repetitions',
        minimum: 2,
      ),
      thresholds: PerformanceThresholds.fromJson(
        json['thresholds'],
        r'$.thresholds',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': performanceConfigSchemaVersion,
    'benchmarkId': benchmarkId,
    'conditions': {
      'baseline': baseline.toJson(),
      'candidate': candidate.toJson(),
    },
    'environment': environment.toJson(),
    'warmupIterations': warmupIterations,
    'repetitions': repetitions,
    'thresholds': thresholds.toJson(),
  };
}

String performanceSampleId(String conditionId, int repetition) {
  validateIdentifier(conditionId, 'conditionId');
  if (repetition < 1 || repetition > 999999) {
    throw ArgumentError.value(
      repetition,
      'repetition',
      'must be between 1 and 999999',
    );
  }
  return '$conditionId-r${repetition.toString().padLeft(6, '0')}';
}

void _requireNonEmpty(Map<String, String> values) {
  for (final entry in values.entries) {
    if (entry.value.trim().isEmpty) {
      throw ArgumentError.value(entry.value, entry.key, 'must not be empty');
    }
  }
}

void _validateGitCommit(String value, String path) {
  if (!RegExp(r'^(?:[a-f0-9]{40}|[a-f0-9]{64})$').hasMatch(value)) {
    throw FormatException('$path must be a full lowercase Git commit digest.');
  }
}

void _validateSha256(String value, String path) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw FormatException('$path must be a lowercase SHA-256 digest.');
  }
}

String? _expectNullableString(Object? value, String path) {
  if (value == null) return null;
  return expectJsonString(value, path);
}

double _expectFinitePositive(Object? value, String path) {
  if (value is! num || !value.isFinite || value <= 0) {
    throw FormatException('$path must be a finite positive number.');
  }
  return value.toDouble();
}

double _expectFiniteNonNegative(Object? value, String path) {
  if (value is! num || !value.isFinite || value < 0) {
    throw FormatException('$path must be a finite non-negative number.');
  }
  return value.toDouble();
}

void _validateFinitePositive(double value, String path) {
  if (!value.isFinite || value <= 0) {
    throw ArgumentError.value(value, path, 'must be finite and positive');
  }
}

void _validateFiniteNonNegative(double value, String path) {
  if (!value.isFinite || value < 0) {
    throw ArgumentError.value(value, path, 'must be finite and non-negative');
  }
}

void _validateNonNegativeInt(int value, String path) {
  if (value < 0) {
    throw ArgumentError.value(value, path, 'must be non-negative');
  }
}
