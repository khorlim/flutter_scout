import 'dart:collection';

import 'digests.dart';
import 'json_support.dart';
import 'task_manifest.dart';

const int benchmarkConfigSchemaVersion = 1;

enum TaskRegime {
  clean('clean'),
  perturbed('perturbed'),
  mixed('mixed');

  const TaskRegime(this.jsonName);

  final String jsonName;

  static TaskRegime parse(Object? value, String path) {
    for (final item in values) {
      if (value == item.jsonName) return item;
    }
    throw FormatException(
      '$path must be one of ${values.map((item) => item.jsonName).join(', ')}.',
    );
  }
}

/// Preregistered repetition class for agent-task conditions.
///
/// This value is part of the config digest, so a result cannot be called
/// borderline after observing it merely to choose a different repetition
/// threshold.
enum AgentResultClassification {
  standard('standard', 10),
  explicitlyBorderline('explicitly_borderline', 20);

  const AgentResultClassification(this.jsonName, this.requiredRepetitions);

  final String jsonName;
  final int requiredRepetitions;

  static AgentResultClassification parse(Object? value, String path) {
    for (final item in values) {
      if (value == item.jsonName) return item;
    }
    throw FormatException('$path must be standard or explicitly_borderline.');
  }
}

class DigestPin {
  DigestPin({required this.id, required this.sha256}) {
    validateIdentifier(id, 'id');
    _validateSha256(sha256, 'sha256');
  }

  final String id;
  final String sha256;

  factory DigestPin.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {'id', 'sha256'}, path);
    return DigestPin(
      id: expectJsonString(json['id'], '$path.id'),
      sha256: expectJsonString(json['sha256'], '$path.sha256'),
    );
  }

  Map<String, Object?> toJson() => {'id': id, 'sha256': sha256};
}

class BenchmarkCondition {
  BenchmarkCondition({
    required this.conditionId,
    required this.scoutGitCommit,
  }) {
    validateIdentifier(conditionId, 'conditionId');
    _validateGitCommit(scoutGitCommit, 'scoutGitCommit');
  }

  final String conditionId;
  final String scoutGitCommit;

  factory BenchmarkCondition.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {'conditionId', 'scoutGitCommit'}, path);
    return BenchmarkCondition(
      conditionId: expectJsonString(json['conditionId'], '$path.conditionId'),
      scoutGitCommit: expectJsonString(
        json['scoutGitCommit'],
        '$path.scoutGitCommit',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'conditionId': conditionId,
    'scoutGitCommit': scoutGitCommit,
  };
}

class AgentConfiguration {
  AgentConfiguration({
    required this.provider,
    required this.model,
    required this.modelSnapshot,
    required this.reasoning,
    required this.systemPrompt,
    required this.toolSchema,
  }) {
    for (final entry in {
      'provider': provider,
      'model': model,
      'modelSnapshot': modelSnapshot,
      'reasoning': reasoning,
    }.entries) {
      if (entry.value.trim().isEmpty) {
        throw ArgumentError.value(entry.value, entry.key, 'must not be empty');
      }
    }
  }

  final String provider;
  final String model;
  final String modelSnapshot;
  final String reasoning;
  final DigestPin systemPrompt;
  final DigestPin toolSchema;

  factory AgentConfiguration.fromJson(Object? value) {
    const path = r'$.agent';
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'provider',
      'model',
      'modelSnapshot',
      'reasoning',
      'systemPrompt',
      'toolSchema',
    }, path);
    return AgentConfiguration(
      provider: expectJsonString(json['provider'], '$path.provider'),
      model: expectJsonString(json['model'], '$path.model'),
      modelSnapshot: expectJsonString(
        json['modelSnapshot'],
        '$path.modelSnapshot',
      ),
      reasoning: expectJsonString(json['reasoning'], '$path.reasoning'),
      systemPrompt: DigestPin.fromJson(
        json['systemPrompt'],
        '$path.systemPrompt',
      ),
      toolSchema: DigestPin.fromJson(json['toolSchema'], '$path.toolSchema'),
    );
  }

  Map<String, Object?> toJson() => {
    'provider': provider,
    'model': model,
    'modelSnapshot': modelSnapshot,
    'reasoning': reasoning,
    'systemPrompt': systemPrompt.toJson(),
    'toolSchema': toolSchema.toJson(),
  };
}

class AppConfiguration {
  AppConfiguration({required this.repository, required this.gitCommit}) {
    if (repository.trim().isEmpty) {
      throw ArgumentError.value(repository, 'repository', 'must not be empty');
    }
    _validateGitCommit(gitCommit, 'gitCommit');
  }

  final String repository;
  final String gitCommit;

  factory AppConfiguration.fromJson(Object? value) {
    const path = r'$.app';
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {'repository', 'gitCommit'}, path);
    return AppConfiguration(
      repository: expectJsonString(json['repository'], '$path.repository'),
      gitCommit: expectJsonString(json['gitCommit'], '$path.gitCommit'),
    );
  }

  Map<String, Object?> toJson() => {
    'repository': repository,
    'gitCommit': gitCommit,
  };
}

class HardwareConfiguration {
  HardwareConfiguration({
    required this.model,
    required this.cpu,
    required this.memoryBytes,
  }) {
    if (model.trim().isEmpty || cpu.trim().isEmpty || memoryBytes < 1) {
      throw ArgumentError(
        'Hardware model, CPU, and positive memory are required.',
      );
    }
  }

  final String model;
  final String cpu;
  final int memoryBytes;

  factory HardwareConfiguration.fromJson(Object? value) {
    const path = r'$.environment.hardware';
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {'model', 'cpu', 'memoryBytes'}, path);
    return HardwareConfiguration(
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

class HostOsConfiguration {
  HostOsConfiguration({
    required this.name,
    required this.version,
    required this.architecture,
  }) {
    if ([name, version, architecture].any((value) => value.trim().isEmpty)) {
      throw ArgumentError('OS name, version, and architecture are required.');
    }
  }

  final String name;
  final String version;
  final String architecture;

  factory HostOsConfiguration.fromJson(Object? value) {
    const path = r'$.environment.hostOs';
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {'name', 'version', 'architecture'}, path);
    return HostOsConfiguration(
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

class SimulatorConfiguration {
  SimulatorConfiguration({
    required this.platform,
    required this.image,
    required this.device,
    required this.logicalWidth,
    required this.logicalHeight,
    required this.devicePixelRatio,
    required this.locale,
    required this.orientation,
  }) {
    if ([
      platform,
      image,
      device,
      locale,
      orientation,
    ].any((value) => value.trim().isEmpty)) {
      throw ArgumentError('All simulator identity fields are required.');
    }
    if (logicalWidth <= 0 || logicalHeight <= 0 || devicePixelRatio <= 0) {
      throw ArgumentError('Simulator viewport values must be positive.');
    }
  }

  final String platform;
  final String image;
  final String device;
  final int logicalWidth;
  final int logicalHeight;
  final double devicePixelRatio;
  final String locale;
  final String orientation;

  factory SimulatorConfiguration.fromJson(Object? value) {
    const path = r'$.environment.simulator';
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'platform',
      'image',
      'device',
      'logicalWidth',
      'logicalHeight',
      'devicePixelRatio',
      'locale',
      'orientation',
    }, path);
    final ratio = json['devicePixelRatio'];
    if (ratio is! num || ratio <= 0) {
      throw FormatException(
        '$path.devicePixelRatio must be a positive number.',
      );
    }
    return SimulatorConfiguration(
      platform: expectJsonString(json['platform'], '$path.platform'),
      image: expectJsonString(json['image'], '$path.image'),
      device: expectJsonString(json['device'], '$path.device'),
      logicalWidth: expectJsonInt(
        json['logicalWidth'],
        '$path.logicalWidth',
        minimum: 1,
      ),
      logicalHeight: expectJsonInt(
        json['logicalHeight'],
        '$path.logicalHeight',
        minimum: 1,
      ),
      devicePixelRatio: ratio.toDouble(),
      locale: expectJsonString(json['locale'], '$path.locale'),
      orientation: expectJsonString(json['orientation'], '$path.orientation'),
    );
  }

  Map<String, Object?> toJson() => {
    'platform': platform,
    'image': image,
    'device': device,
    'logicalWidth': logicalWidth,
    'logicalHeight': logicalHeight,
    'devicePixelRatio': devicePixelRatio,
    'locale': locale,
    'orientation': orientation,
  };
}

class ToolchainConfiguration {
  ToolchainConfiguration({
    required this.flutterVersion,
    required this.dartVersion,
    required this.platformSdkVersion,
  }) {
    if ([
      flutterVersion,
      dartVersion,
      platformSdkVersion,
    ].any((value) => value.trim().isEmpty)) {
      throw ArgumentError('All toolchain versions are required.');
    }
  }

  final String flutterVersion;
  final String dartVersion;
  final String platformSdkVersion;

  factory ToolchainConfiguration.fromJson(Object? value) {
    const path = r'$.environment.toolchains';
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'flutterVersion',
      'dartVersion',
      'platformSdkVersion',
    }, path);
    return ToolchainConfiguration(
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

class BenchmarkEnvironment {
  const BenchmarkEnvironment({
    required this.hardware,
    required this.hostOs,
    required this.simulator,
    required this.toolchains,
  });

  final HardwareConfiguration hardware;
  final HostOsConfiguration hostOs;
  final SimulatorConfiguration simulator;
  final ToolchainConfiguration toolchains;

  factory BenchmarkEnvironment.fromJson(Object? value) {
    const path = r'$.environment';
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'hardware',
      'hostOs',
      'simulator',
      'toolchains',
    }, path);
    return BenchmarkEnvironment(
      hardware: HardwareConfiguration.fromJson(json['hardware']),
      hostOs: HostOsConfiguration.fromJson(json['hostOs']),
      simulator: SimulatorConfiguration.fromJson(json['simulator']),
      toolchains: ToolchainConfiguration.fromJson(json['toolchains']),
    );
  }

  Map<String, Object?> toJson() => {
    'hardware': hardware.toJson(),
    'hostOs': hostOs.toJson(),
    'simulator': simulator.toJson(),
    'toolchains': toolchains.toJson(),
  };
}

class BenchmarkBudget {
  BenchmarkBudget({
    required this.maxActions,
    required this.maxWallTimeMs,
    required this.maxTokens,
    required this.maxToolCalls,
    required this.maxResponseBytes,
    required this.maxScreenshots,
  }) {
    if ([
      maxActions,
      maxWallTimeMs,
      maxTokens,
      maxToolCalls,
      maxResponseBytes,
      maxScreenshots,
    ].any((value) => value < 1)) {
      throw ArgumentError('Every benchmark budget must be positive.');
    }
  }

  final int maxActions;
  final int maxWallTimeMs;
  final int maxTokens;
  final int maxToolCalls;
  final int maxResponseBytes;
  final int maxScreenshots;

  factory BenchmarkBudget.fromJson(Object? value) {
    const path = r'$.budget';
    final json = expectJsonObject(value, path);
    const keys = {
      'maxActions',
      'maxWallTimeMs',
      'maxTokens',
      'maxToolCalls',
      'maxResponseBytes',
      'maxScreenshots',
    };
    rejectUnknownKeys(json, keys, path);
    int read(String key) => expectJsonInt(json[key], '$path.$key', minimum: 1);
    return BenchmarkBudget(
      maxActions: read('maxActions'),
      maxWallTimeMs: read('maxWallTimeMs'),
      maxTokens: read('maxTokens'),
      maxToolCalls: read('maxToolCalls'),
      maxResponseBytes: read('maxResponseBytes'),
      maxScreenshots: read('maxScreenshots'),
    );
  }

  Map<String, Object?> toJson() => {
    'maxActions': maxActions,
    'maxWallTimeMs': maxWallTimeMs,
    'maxTokens': maxTokens,
    'maxToolCalls': maxToolCalls,
    'maxResponseBytes': maxResponseBytes,
    'maxScreenshots': maxScreenshots,
  };
}

class TemplateFamily {
  TemplateFamily({
    required this.familyId,
    required Iterable<String> templateIds,
  }) : templateIds = List<String>.unmodifiable(templateIds) {
    validateIdentifier(familyId, 'familyId');
    if (this.templateIds.isEmpty) {
      throw ArgumentError.value(
        templateIds,
        'templateIds',
        'must not be empty',
      );
    }
    final unique = <String>{};
    for (final templateId in this.templateIds) {
      validateIdentifier(templateId, 'templateId');
      if (!unique.add(templateId)) {
        throw ArgumentError(
          'Template family `$familyId` repeats `$templateId`.',
        );
      }
    }
  }

  final String familyId;
  final List<String> templateIds;

  factory TemplateFamily.fromJson(Object? value, int index) {
    final path = r'$.templateFamilies[' + '$index]';
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {'familyId', 'templateIds'}, path);
    final values = expectJsonList(json['templateIds'], '$path.templateIds');
    return TemplateFamily(
      familyId: expectJsonString(json['familyId'], '$path.familyId'),
      templateIds: [
        for (var item = 0; item < values.length; item++)
          expectJsonString(values[item], '$path.templateIds[$item]'),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'familyId': familyId,
    'templateIds': templateIds,
  };
}

enum ControlledComparisonRole {
  screenshotCoordinateOnly('screenshot_coordinate_only'),
  currentReleasedScout('current_released_scout'),
  candidateScout('candidate_scout'),
  perfectHandleCeiling('perfect_handle_ceiling');

  const ControlledComparisonRole(this.jsonName);

  final String jsonName;

  static ControlledComparisonRole parse(Object? value, String path) {
    for (final role in values) {
      if (value == role.jsonName) return role;
    }
    throw FormatException(
      '$path must be one of '
      '${values.map((role) => role.jsonName).join(', ')}.',
    );
  }
}

class ControlledComparisonCondition {
  ControlledComparisonCondition({
    required this.role,
    required this.conditionId,
    required this.toolSchema,
    required this.implementation,
  }) {
    validateIdentifier(conditionId, 'conditionId');
  }

  final ControlledComparisonRole role;
  final String conditionId;
  final DigestPin toolSchema;
  final DigestPin implementation;

  factory ControlledComparisonCondition.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'role',
      'conditionId',
      'toolSchema',
      'implementation',
    }, path);
    return ControlledComparisonCondition(
      role: ControlledComparisonRole.parse(json['role'], '$path.role'),
      conditionId: expectJsonString(json['conditionId'], '$path.conditionId'),
      toolSchema: DigestPin.fromJson(json['toolSchema'], '$path.toolSchema'),
      implementation: DigestPin.fromJson(
        json['implementation'],
        '$path.implementation',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'role': role.jsonName,
    'conditionId': conditionId,
    'toolSchema': toolSchema.toJson(),
    'implementation': implementation.toJson(),
  };
}

class ControlledComparison {
  ControlledComparison({
    required this.resetProtocol,
    required Iterable<ControlledComparisonCondition> conditions,
  }) : conditions = List<ControlledComparisonCondition>.unmodifiable(
         conditions,
       ) {
    if (this.conditions.length < 3 || this.conditions.length > 4) {
      throw ArgumentError(
        'Controlled comparison requires three roles and permits one optional '
        'perfect-handle ceiling.',
      );
    }
    final byRole = <ControlledComparisonRole, ControlledComparisonCondition>{};
    final conditionIds = <String>{};
    for (final condition in this.conditions) {
      if (byRole.containsKey(condition.role)) {
        throw ArgumentError(
          'Controlled comparison repeats role `${condition.role.jsonName}`.',
        );
      }
      byRole[condition.role] = condition;
      if (!conditionIds.add(condition.conditionId)) {
        throw ArgumentError(
          'Controlled comparison repeats condition id '
          '`${condition.conditionId}`.',
        );
      }
    }
    const requiredRoles = {
      ControlledComparisonRole.screenshotCoordinateOnly,
      ControlledComparisonRole.currentReleasedScout,
      ControlledComparisonRole.candidateScout,
    };
    final missing = requiredRoles.difference(byRole.keys.toSet());
    if (missing.isNotEmpty) {
      throw ArgumentError(
        'Controlled comparison is missing roles: '
        '${missing.map((role) => role.jsonName).join(', ')}.',
      );
    }
  }

  static const randomizationAlgorithm = 'stable_balanced_role_rotation_v1';

  final DigestPin resetProtocol;
  final List<ControlledComparisonCondition> conditions;

  Map<ControlledComparisonRole, ControlledComparisonCondition>
  get conditionsByRole => UnmodifiableMapView({
    for (final condition in conditions) condition.role: condition,
  });

  factory ControlledComparison.fromJson(Object? value) {
    const path = r'$.controlledComparison';
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'randomizationAlgorithm',
      'freshResetPerEpisode',
      'identicalTaskSeedsAcrossRoles',
      'resetProtocol',
      'conditions',
    }, path);
    final algorithm = expectJsonString(
      json['randomizationAlgorithm'],
      '$path.randomizationAlgorithm',
    );
    if (algorithm != randomizationAlgorithm) {
      throw FormatException(
        '$path.randomizationAlgorithm must be '
        '`$randomizationAlgorithm`.',
      );
    }
    if (!expectJsonBool(
      json['freshResetPerEpisode'],
      '$path.freshResetPerEpisode',
    )) {
      throw FormatException('$path.freshResetPerEpisode must be true.');
    }
    if (!expectJsonBool(
      json['identicalTaskSeedsAcrossRoles'],
      '$path.identicalTaskSeedsAcrossRoles',
    )) {
      throw FormatException(
        '$path.identicalTaskSeedsAcrossRoles must be true.',
      );
    }
    final values = expectJsonList(json['conditions'], '$path.conditions');
    return ControlledComparison(
      resetProtocol: DigestPin.fromJson(
        json['resetProtocol'],
        '$path.resetProtocol',
      ),
      conditions: [
        for (var index = 0; index < values.length; index++)
          ControlledComparisonCondition.fromJson(
            values[index],
            '$path.conditions[$index]',
          ),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'randomizationAlgorithm': randomizationAlgorithm,
    'freshResetPerEpisode': true,
    'identicalTaskSeedsAcrossRoles': true,
    'resetProtocol': resetProtocol.toJson(),
    'conditions': [for (final condition in conditions) condition.toJson()],
  };
}

class BenchmarkConfig {
  BenchmarkConfig({
    required this.benchmarkId,
    required this.catalogSha256,
    required this.current,
    required this.candidate,
    required this.agent,
    required this.app,
    required this.environment,
    required this.budget,
    required this.repetitions,
    required this.agentResultClassification,
    required this.randomizationSeed,
    required this.taskRegime,
    required Iterable<BenchmarkSplit> includedSplits,
    required Iterable<TemplateFamily> templateFamilies,
    this.controlledComparison,
  }) : includedSplits = List<BenchmarkSplit>.unmodifiable(includedSplits),
       templateFamilies = List<TemplateFamily>.unmodifiable(templateFamilies) {
    validateIdentifier(benchmarkId, 'benchmarkId');
    _validateSha256(catalogSha256, 'catalogSha256');
    if (current.conditionId == candidate.conditionId) {
      throw ArgumentError('Current and candidate condition ids must differ.');
    }
    if (current.scoutGitCommit == candidate.scoutGitCommit) {
      throw ArgumentError('Current and candidate Git commits must differ.');
    }
    if (repetitions < 1) {
      throw ArgumentError.value(repetitions, 'repetitions', 'must be positive');
    }
    if (randomizationSeed < 0 || randomizationSeed > 0x7fffffff) {
      throw ArgumentError.value(
        randomizationSeed,
        'randomizationSeed',
        'must be between 0 and 2147483647',
      );
    }
    if (this.includedSplits.isEmpty ||
        this.includedSplits.toSet().length != this.includedSplits.length) {
      throw ArgumentError('includedSplits must be non-empty and unique.');
    }
    final familyIds = <String>{};
    final templateIds = <String>{};
    for (final family in this.templateFamilies) {
      if (!familyIds.add(family.familyId)) {
        throw ArgumentError('Duplicate template family `${family.familyId}`.');
      }
      for (final templateId in family.templateIds) {
        if (!templateIds.add(templateId)) {
          throw ArgumentError(
            'Template `$templateId` appears in more than one family.',
          );
        }
      }
    }
    final comparison = controlledComparison;
    if (comparison != null) {
      final byRole = comparison.conditionsByRole;
      final configuredCurrent =
          byRole[ControlledComparisonRole.currentReleasedScout]!;
      final configuredCandidate =
          byRole[ControlledComparisonRole.candidateScout]!;
      if (configuredCurrent.conditionId != current.conditionId) {
        throw ArgumentError(
          'The current-released role condition id must equal '
          '`${current.conditionId}`.',
        );
      }
      if (configuredCandidate.conditionId != candidate.conditionId) {
        throw ArgumentError(
          'The candidate role condition id must equal '
          '`${candidate.conditionId}`.',
        );
      }
      if (configuredCandidate.toolSchema.id != agent.toolSchema.id ||
          configuredCandidate.toolSchema.sha256 != agent.toolSchema.sha256) {
        throw ArgumentError(
          'The candidate role tool schema must equal the legacy agent '
          'tool-schema pin.',
        );
      }
    }
  }

  final String benchmarkId;
  final String catalogSha256;
  final BenchmarkCondition current;
  final BenchmarkCondition candidate;
  final AgentConfiguration agent;
  final AppConfiguration app;
  final BenchmarkEnvironment environment;
  final BenchmarkBudget budget;
  final int repetitions;
  final AgentResultClassification agentResultClassification;
  final int randomizationSeed;
  final TaskRegime taskRegime;
  final List<BenchmarkSplit> includedSplits;
  final List<TemplateFamily> templateFamilies;
  final ControlledComparison? controlledComparison;

  String get sha256 => jsonSha256(toJson());

  List<String> get conditionIds => controlledComparison == null
      ? [current.conditionId, candidate.conditionId]
      : [
          for (final condition in controlledComparison!.conditions)
            condition.conditionId,
        ];

  Map<String, ControlledComparisonRole>? get conditionRoles =>
      controlledComparison == null
      ? null
      : UnmodifiableMapView({
          for (final condition in controlledComparison!.conditions)
            condition.conditionId: condition.role,
        });

  Map<String, String> get templateFamilyByTemplateId =>
      UnmodifiableMapView(<String, String>{
        for (final family in templateFamilies)
          for (final templateId in family.templateIds)
            templateId: family.familyId,
      });

  factory BenchmarkConfig.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$');
    rejectUnknownKeys(json, const {
      'schemaVersion',
      'benchmarkId',
      'catalogSha256',
      'conditions',
      'agent',
      'app',
      'environment',
      'budget',
      'repetitions',
      'agentResultClassification',
      'randomizationSeed',
      'taskRegime',
      'includedSplits',
      'templateFamilies',
      'controlledComparison',
    }, r'$');
    final version = expectJsonInt(json['schemaVersion'], r'$.schemaVersion');
    if (version != benchmarkConfigSchemaVersion) {
      throw FormatException(
        'Unsupported benchmark config schemaVersion $version; expected '
        '$benchmarkConfigSchemaVersion.',
      );
    }
    final conditions = expectJsonObject(json['conditions'], r'$.conditions');
    rejectUnknownKeys(conditions, const {
      'current',
      'candidate',
    }, r'$.conditions');
    final splitValues = expectJsonList(
      json['includedSplits'],
      r'$.includedSplits',
    );
    final familyValues = expectJsonList(
      json['templateFamilies'],
      r'$.templateFamilies',
    );
    return BenchmarkConfig(
      benchmarkId: expectJsonString(json['benchmarkId'], r'$.benchmarkId'),
      catalogSha256: expectJsonString(
        json['catalogSha256'],
        r'$.catalogSha256',
      ),
      current: BenchmarkCondition.fromJson(
        conditions['current'],
        r'$.conditions.current',
      ),
      candidate: BenchmarkCondition.fromJson(
        conditions['candidate'],
        r'$.conditions.candidate',
      ),
      agent: AgentConfiguration.fromJson(json['agent']),
      app: AppConfiguration.fromJson(json['app']),
      environment: BenchmarkEnvironment.fromJson(json['environment']),
      budget: BenchmarkBudget.fromJson(json['budget']),
      repetitions: expectJsonInt(
        json['repetitions'],
        r'$.repetitions',
        minimum: 1,
      ),
      agentResultClassification: AgentResultClassification.parse(
        json['agentResultClassification'],
        r'$.agentResultClassification',
      ),
      randomizationSeed: expectJsonInt(
        json['randomizationSeed'],
        r'$.randomizationSeed',
        minimum: 0,
      ),
      taskRegime: TaskRegime.parse(json['taskRegime'], r'$.taskRegime'),
      includedSplits: [
        for (var index = 0; index < splitValues.length; index++)
          BenchmarkSplit.parse(
            splitValues[index],
            r'$.includedSplits[' + '$index]',
          ),
      ],
      templateFamilies: [
        for (var index = 0; index < familyValues.length; index++)
          TemplateFamily.fromJson(familyValues[index], index),
      ],
      controlledComparison: json['controlledComparison'] == null
          ? null
          : ControlledComparison.fromJson(json['controlledComparison']),
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': benchmarkConfigSchemaVersion,
    'benchmarkId': benchmarkId,
    'catalogSha256': catalogSha256,
    'conditions': {
      'current': current.toJson(),
      'candidate': candidate.toJson(),
    },
    'agent': agent.toJson(),
    'app': app.toJson(),
    'environment': environment.toJson(),
    'budget': budget.toJson(),
    'repetitions': repetitions,
    'agentResultClassification': agentResultClassification.jsonName,
    'randomizationSeed': randomizationSeed,
    'taskRegime': taskRegime.jsonName,
    'includedSplits': [for (final split in includedSplits) split.jsonName],
    'templateFamilies': [
      for (final family in templateFamilies) family.toJson(),
    ],
    if (controlledComparison != null)
      'controlledComparison': controlledComparison!.toJson(),
  };
}

void _validateSha256(String value, String path) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw FormatException('$path must be a lowercase SHA-256 digest.');
  }
}

void _validateGitCommit(String value, String path) {
  if (!RegExp(r'^(?:[a-f0-9]{40}|[a-f0-9]{64})$').hasMatch(value)) {
    throw FormatException('$path must be a full lowercase Git commit digest.');
  }
}
