import 'dart:collection';

import 'json_support.dart';

const int taskManifestSchemaVersion = 1;
const int agentTaskSchemaVersion = 1;

enum BenchmarkSplit {
  publicDevelopment('public_development'),
  privateValidation('private_validation'),
  frozenHiddenRelease('frozen_hidden_release');

  const BenchmarkSplit(this.jsonName);

  final String jsonName;

  static BenchmarkSplit parse(Object? value, String path) {
    for (final split in values) {
      if (value == split.jsonName) return split;
    }
    throw FormatException(
      '$path must be one of ${values.map((value) => value.jsonName).join(', ')}.',
    );
  }
}

class TaskBudget {
  const TaskBudget({
    required this.maxActions,
    required this.maxWallTimeMs,
    this.maxTokens,
  }) : assert(maxActions > 0),
       assert(maxWallTimeMs > 0),
       assert(maxTokens == null || maxTokens > 0);

  final int maxActions;
  final int maxWallTimeMs;
  final int? maxTokens;

  factory TaskBudget.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$.agentVisible.budget');
    rejectUnknownKeys(json, const {
      'maxActions',
      'maxWallTimeMs',
      'maxTokens',
    }, r'$.agentVisible.budget');
    return TaskBudget(
      maxActions: expectJsonInt(
        json['maxActions'],
        r'$.agentVisible.budget.maxActions',
        minimum: 1,
      ),
      maxWallTimeMs: expectJsonInt(
        json['maxWallTimeMs'],
        r'$.agentVisible.budget.maxWallTimeMs',
        minimum: 1,
      ),
      maxTokens: json['maxTokens'] == null
          ? null
          : expectJsonInt(
              json['maxTokens'],
              r'$.agentVisible.budget.maxTokens',
              minimum: 1,
            ),
    );
  }

  Map<String, Object?> toJson() => {
    'maxActions': maxActions,
    'maxWallTimeMs': maxWallTimeMs,
    if (maxTokens != null) 'maxTokens': maxTokens,
  };
}

class AgentTaskDefinition {
  AgentTaskDefinition({
    required this.instruction,
    required Iterable<String> allowedTools,
    required this.budget,
  }) : allowedTools = List<String>.unmodifiable(allowedTools) {
    if (instruction.trim().isEmpty) {
      throw ArgumentError.value(
        instruction,
        'instruction',
        'must not be empty',
      );
    }
    if (this.allowedTools.any((tool) => tool.trim().isEmpty)) {
      throw ArgumentError.value(
        allowedTools,
        'allowedTools',
        'contains an empty tool',
      );
    }
  }

  final String instruction;
  final List<String> allowedTools;
  final TaskBudget budget;

  factory AgentTaskDefinition.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$.agentVisible');
    rejectUnknownKeys(json, const {
      'instruction',
      'allowedTools',
      'budget',
    }, r'$.agentVisible');
    final rawTools = expectJsonList(
      json['allowedTools'],
      r'$.agentVisible.allowedTools',
    );
    return AgentTaskDefinition(
      instruction: expectJsonString(
        json['instruction'],
        r'$.agentVisible.instruction',
      ),
      allowedTools: [
        for (var index = 0; index < rawTools.length; index++)
          expectJsonString(rawTools[index], r'$.agentVisible.allowedTools'),
      ],
      budget: TaskBudget.fromJson(json['budget']),
    );
  }

  Map<String, Object?> toJson() => {
    'instruction': instruction,
    'allowedTools': allowedTools,
    'budget': budget.toJson(),
  };
}

class HiddenHarnessDefinition {
  HiddenHarnessDefinition({
    required this.oracleId,
    required this.setupFixture,
    required Iterable<String> successPredicateIds,
    required Iterable<String> forbiddenPredicateIds,
    required this.teardownFixture,
  }) : successPredicateIds = List<String>.unmodifiable(successPredicateIds),
       forbiddenPredicateIds = List<String>.unmodifiable(
         forbiddenPredicateIds,
       ) {
    validateIdentifier(oracleId, 'oracleId');
    validateIdentifier(setupFixture, 'setupFixture');
    validateIdentifier(teardownFixture, 'teardownFixture');
    if (this.successPredicateIds.isEmpty) {
      throw ArgumentError.value(
        successPredicateIds,
        'successPredicateIds',
        'must contain at least one predicate',
      );
    }
    for (final predicate in [
      ...this.successPredicateIds,
      ...this.forbiddenPredicateIds,
    ]) {
      validateIdentifier(predicate, 'predicateId');
    }
  }

  final String oracleId;
  final String setupFixture;
  final List<String> successPredicateIds;
  final List<String> forbiddenPredicateIds;
  final String teardownFixture;

  factory HiddenHarnessDefinition.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$.hiddenHarness');
    rejectUnknownKeys(json, const {
      'oracleId',
      'setupFixture',
      'successPredicateIds',
      'forbiddenPredicateIds',
      'teardownFixture',
    }, r'$.hiddenHarness');
    List<String> predicates(String name) {
      final raw = expectJsonList(json[name], r'$.hiddenHarness.$name');
      return [
        for (var index = 0; index < raw.length; index++)
          expectJsonString(raw[index], r'$.hiddenHarness.$name[$index]'),
      ];
    }

    return HiddenHarnessDefinition(
      oracleId: expectJsonString(json['oracleId'], r'$.hiddenHarness.oracleId'),
      setupFixture: expectJsonString(
        json['setupFixture'],
        r'$.hiddenHarness.setupFixture',
      ),
      successPredicateIds: predicates('successPredicateIds'),
      forbiddenPredicateIds: predicates('forbiddenPredicateIds'),
      teardownFixture: expectJsonString(
        json['teardownFixture'],
        r'$.hiddenHarness.teardownFixture',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'oracleId': oracleId,
    'setupFixture': setupFixture,
    'successPredicateIds': successPredicateIds,
    'forbiddenPredicateIds': forbiddenPredicateIds,
    'teardownFixture': teardownFixture,
  };
}

class TaskVariant {
  TaskVariant({
    required this.variantId,
    required this.seed,
    Map<String, Object?> parameters = const {},
  }) : parameters = UnmodifiableMapView(deepCopyJsonObject(parameters)) {
    validateIdentifier(variantId, 'variantId');
  }

  final String variantId;
  final int seed;
  final Map<String, Object?> parameters;

  factory TaskVariant.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$.variant');
    rejectUnknownKeys(json, const {
      'variantId',
      'seed',
      'parameters',
    }, r'$.variant');
    return TaskVariant(
      variantId: expectJsonString(json['variantId'], r'$.variant.variantId'),
      seed: expectJsonInt(json['seed'], r'$.variant.seed'),
      parameters: expectJsonObject(json['parameters'], r'$.variant.parameters'),
    );
  }

  Map<String, Object?> toJson() => {
    'variantId': variantId,
    'seed': seed,
    'parameters': deepCopyJsonObject(parameters),
  };
}

class AgentTaskView {
  const AgentTaskView({required this.taskId, required this.definition});

  final String taskId;
  final AgentTaskDefinition definition;

  Map<String, Object?> toJson() => {
    'schemaVersion': agentTaskSchemaVersion,
    'taskId': taskId,
    ...definition.toJson(),
  };
}

class TaskManifest {
  TaskManifest({
    required this.taskId,
    required this.templateId,
    required this.split,
    required this.agentVisible,
    required this.hiddenHarness,
    required this.variant,
  }) {
    validateIdentifier(taskId, 'taskId');
    validateIdentifier(templateId, 'templateId');
  }

  final String taskId;
  final String templateId;
  final BenchmarkSplit split;
  final AgentTaskDefinition agentVisible;
  final HiddenHarnessDefinition hiddenHarness;
  final TaskVariant variant;

  factory TaskManifest.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$');
    rejectUnknownKeys(json, const {
      'schemaVersion',
      'taskId',
      'templateId',
      'split',
      'agentVisible',
      'hiddenHarness',
      'variant',
    }, r'$');
    final version = expectJsonInt(json['schemaVersion'], r'$.schemaVersion');
    if (version != taskManifestSchemaVersion) {
      throw FormatException(
        'Unsupported task manifest schemaVersion $version; expected '
        '$taskManifestSchemaVersion.',
      );
    }
    return TaskManifest(
      taskId: expectJsonString(json['taskId'], r'$.taskId'),
      templateId: expectJsonString(json['templateId'], r'$.templateId'),
      split: BenchmarkSplit.parse(json['split'], r'$.split'),
      agentVisible: AgentTaskDefinition.fromJson(json['agentVisible']),
      hiddenHarness: HiddenHarnessDefinition.fromJson(json['hiddenHarness']),
      variant: TaskVariant.fromJson(json['variant']),
    );
  }

  AgentTaskView toAgentView() =>
      AgentTaskView(taskId: taskId, definition: agentVisible);

  Map<String, Object?> toJson() => {
    'schemaVersion': taskManifestSchemaVersion,
    'taskId': taskId,
    'templateId': templateId,
    'split': split.jsonName,
    'agentVisible': agentVisible.toJson(),
    'hiddenHarness': hiddenHarness.toJson(),
    'variant': variant.toJson(),
  };
}
