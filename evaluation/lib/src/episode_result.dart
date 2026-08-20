import 'dart:collection';

import 'failure.dart';
import 'json_support.dart';
import 'safety_metrics.dart';
import 'task_manifest.dart';

const int episodeResultSchemaVersion = 1;

class EpisodeUsage {
  const EpisodeUsage({
    required this.actions,
    required this.wallTimeMs,
    this.tokens,
  }) : assert(actions >= 0),
       assert(wallTimeMs >= 0),
       assert(tokens == null || tokens >= 0);

  final int actions;
  final int wallTimeMs;
  final int? tokens;

  bool respects(TaskBudget budget) {
    if (actions > budget.maxActions || wallTimeMs > budget.maxWallTimeMs) {
      return false;
    }
    final tokenLimit = budget.maxTokens;
    if (tokenLimit == null) return true;
    return tokens != null && tokens! <= tokenLimit;
  }

  factory EpisodeUsage.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$.usage');
    rejectUnknownKeys(json, const {
      'actions',
      'wallTimeMs',
      'tokens',
    }, r'$.usage');
    return EpisodeUsage(
      actions: expectJsonInt(json['actions'], r'$.usage.actions', minimum: 0),
      wallTimeMs: expectJsonInt(
        json['wallTimeMs'],
        r'$.usage.wallTimeMs',
        minimum: 0,
      ),
      tokens: json['tokens'] == null
          ? null
          : expectJsonInt(json['tokens'], r'$.usage.tokens', minimum: 0),
    );
  }

  Map<String, Object?> toJson() => {
    'actions': actions,
    'wallTimeMs': wallTimeMs,
    if (tokens != null) 'tokens': tokens,
  };
}

class OracleOutcome {
  const OracleOutcome({
    required this.valid,
    required this.successPredicatesMet,
    required this.forbiddenStateObserved,
    required this.blockingRuntimeFaultObserved,
    required this.budgetRespected,
  });

  final bool valid;
  final bool successPredicatesMet;
  final bool forbiddenStateObserved;
  final bool blockingRuntimeFaultObserved;
  final bool budgetRespected;

  bool get cleanSuccess =>
      valid &&
      successPredicatesMet &&
      !forbiddenStateObserved &&
      !blockingRuntimeFaultObserved &&
      budgetRespected;

  factory OracleOutcome.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$.oracle');
    rejectUnknownKeys(json, const {
      'valid',
      'successPredicatesMet',
      'forbiddenStateObserved',
      'blockingRuntimeFaultObserved',
      'budgetRespected',
    }, r'$.oracle');
    return OracleOutcome(
      valid: expectJsonBool(json['valid'], r'$.oracle.valid'),
      successPredicatesMet: expectJsonBool(
        json['successPredicatesMet'],
        r'$.oracle.successPredicatesMet',
      ),
      forbiddenStateObserved: expectJsonBool(
        json['forbiddenStateObserved'],
        r'$.oracle.forbiddenStateObserved',
      ),
      blockingRuntimeFaultObserved: expectJsonBool(
        json['blockingRuntimeFaultObserved'],
        r'$.oracle.blockingRuntimeFaultObserved',
      ),
      budgetRespected: expectJsonBool(
        json['budgetRespected'],
        r'$.oracle.budgetRespected',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'valid': valid,
    'successPredicatesMet': successPredicatesMet,
    'forbiddenStateObserved': forbiddenStateObserved,
    'blockingRuntimeFaultObserved': blockingRuntimeFaultObserved,
    'budgetRespected': budgetRespected,
  };
}

class RawEpisodeData {
  RawEpisodeData({
    Iterable<Map<String, Object?>> agentEvents = const [],
    Iterable<Map<String, Object?>> toolEvents = const [],
    Iterable<Map<String, Object?>> harnessEvents = const [],
  }) : agentEvents = deepCopyJsonEvents(agentEvents),
       toolEvents = deepCopyJsonEvents(toolEvents),
       harnessEvents = deepCopyJsonEvents(harnessEvents);

  final List<Map<String, Object?>> agentEvents;
  final List<Map<String, Object?>> toolEvents;
  final List<Map<String, Object?>> harnessEvents;

  RawEpisodeData appendToolEvent(Map<String, Object?> event) => RawEpisodeData(
    agentEvents: agentEvents,
    toolEvents: [...toolEvents, event],
    harnessEvents: harnessEvents,
  );

  RawEpisodeData appendHarnessEvent(Map<String, Object?> event) =>
      RawEpisodeData(
        agentEvents: agentEvents,
        toolEvents: toolEvents,
        harnessEvents: [...harnessEvents, event],
      );

  factory RawEpisodeData.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$.raw');
    rejectUnknownKeys(json, const {
      'agentEvents',
      'toolEvents',
      'harnessEvents',
    }, r'$.raw');
    List<Map<String, Object?>> events(String name) {
      final raw = expectJsonList(json[name], r'$.raw.$name');
      return [
        for (var index = 0; index < raw.length; index++)
          expectJsonObject(raw[index], r'$.raw.$name[$index]'),
      ];
    }

    return RawEpisodeData(
      agentEvents: events('agentEvents'),
      toolEvents: events('toolEvents'),
      harnessEvents: events('harnessEvents'),
    );
  }

  Map<String, Object?> toJson() => {
    'agentEvents': deepCopyJsonEvents(agentEvents),
    'toolEvents': deepCopyJsonEvents(toolEvents),
    'harnessEvents': deepCopyJsonEvents(harnessEvents),
  };
}

class EpisodeResult {
  EpisodeResult({
    required this.episodeId,
    required this.taskId,
    required this.templateId,
    required this.split,
    required this.condition,
    required DateTime startedAt,
    required DateTime finishedAt,
    required this.validEpisode,
    required this.passed,
    required this.agentClaimedSuccess,
    required this.oracle,
    required this.usage,
    required this.failure,
    required Map<String, num> metrics,
    required this.safetyEvidence,
    required this.raw,
  }) : startedAt = startedAt.toUtc(),
       finishedAt = finishedAt.toUtc(),
       metrics = UnmodifiableMapView(Map<String, num>.from(metrics)) {
    validateIdentifier(episodeId, 'episodeId');
    validateIdentifier(taskId, 'taskId');
    validateIdentifier(templateId, 'templateId');
    validateIdentifier(condition, 'condition');
    if (this.finishedAt.isBefore(this.startedAt)) {
      throw ArgumentError('finishedAt must not be before startedAt.');
    }
    if (validEpisode != oracle.valid) {
      throw ArgumentError('validEpisode must match oracle.valid.');
    }
    if (passed != (oracle.cleanSuccess && !safetyEvidence.hasViolations)) {
      throw ArgumentError(
        'passed must exactly match clean oracle success with no observed '
        'safety violation.',
      );
    }
    if (passed && failure != null) {
      throw ArgumentError('A passing episode cannot contain a failure.');
    }
    if (!passed && failure == null) {
      throw ArgumentError('A failing or invalid episode requires one failure.');
    }
    if (!validEpisode && failure?.category != FailureCategory.harnessInvalid) {
      throw ArgumentError('An invalid episode must be HARNESS_INVALID.');
    }
    if (validEpisode && failure?.category == FailureCategory.harnessInvalid) {
      throw ArgumentError('A valid episode cannot be HARNESS_INVALID.');
    }
    final falseSuccess = safetyEvidence[SafetyGuardrail.falseSuccess];
    final inferredFalseSuccess =
        validEpisode && agentClaimedSuccess && !oracle.cleanSuccess;
    if ((failure?.category == FailureCategory.safetyFalseSuccess ||
            inferredFalseSuccess) &&
        (falseSuccess.status != SafetyMeasurementStatus.measured ||
            falseSuccess.violations == 0)) {
      throw ArgumentError(
        'A false-success outcome requires independently measured '
        'false-success violation evidence.',
      );
    }
    final forbiddenState =
        safetyEvidence[SafetyGuardrail.forbiddenStateMutation];
    if (oracle.forbiddenStateObserved &&
        (forbiddenState.status != SafetyMeasurementStatus.measured ||
            forbiddenState.violations == 0)) {
      throw ArgumentError(
        'An observed forbidden state requires independently measured '
        'forbidden-state violation evidence.',
      );
    }
    if (safetyEvidence.hasViolations && validEpisode && failure == null) {
      throw ArgumentError(
        'A valid episode with a safety violation requires a first-causal '
        'failure.',
      );
    }
    if (safetyEvidence.hasViolations &&
        validEpisode &&
        failure?.severity != FailureSeverity.releaseBlocking) {
      throw ArgumentError(
        'Every observed zero-tolerance safety violation must be '
        'release-blocking.',
      );
    }
  }

  final String episodeId;
  final String taskId;
  final String templateId;
  final BenchmarkSplit split;
  final String condition;
  final DateTime startedAt;
  final DateTime finishedAt;
  final bool validEpisode;
  final bool passed;
  final bool agentClaimedSuccess;
  final OracleOutcome oracle;
  final EpisodeUsage usage;
  final EpisodeFailure? failure;
  final Map<String, num> metrics;
  final EpisodeSafetyEvidence safetyEvidence;
  final RawEpisodeData raw;

  factory EpisodeResult.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$');
    rejectUnknownKeys(json, const {
      'schemaVersion',
      'episodeId',
      'taskId',
      'templateId',
      'split',
      'condition',
      'startedAt',
      'finishedAt',
      'validEpisode',
      'passed',
      'agentClaimedSuccess',
      'oracle',
      'usage',
      'failure',
      'metrics',
      'safetyGuardrails',
      'raw',
    }, r'$');
    final version = expectJsonInt(json['schemaVersion'], r'$.schemaVersion');
    if (version != episodeResultSchemaVersion) {
      throw FormatException(
        'Unsupported episode result schemaVersion $version; expected '
        '$episodeResultSchemaVersion.',
      );
    }
    return EpisodeResult(
      episodeId: expectJsonString(json['episodeId'], r'$.episodeId'),
      taskId: expectJsonString(json['taskId'], r'$.taskId'),
      templateId: expectJsonString(json['templateId'], r'$.templateId'),
      split: BenchmarkSplit.parse(json['split'], r'$.split'),
      condition: expectJsonString(json['condition'], r'$.condition'),
      startedAt: DateTime.parse(
        expectJsonString(json['startedAt'], r'$.startedAt'),
      ),
      finishedAt: DateTime.parse(
        expectJsonString(json['finishedAt'], r'$.finishedAt'),
      ),
      validEpisode: expectJsonBool(json['validEpisode'], r'$.validEpisode'),
      passed: expectJsonBool(json['passed'], r'$.passed'),
      agentClaimedSuccess: expectJsonBool(
        json['agentClaimedSuccess'],
        r'$.agentClaimedSuccess',
      ),
      oracle: OracleOutcome.fromJson(json['oracle']),
      usage: EpisodeUsage.fromJson(json['usage']),
      failure: json['failure'] == null
          ? null
          : EpisodeFailure.fromJson(json['failure']),
      metrics: expectNumericMap(json['metrics'], r'$.metrics'),
      safetyEvidence: EpisodeSafetyEvidence.fromJson(json['safetyGuardrails']),
      raw: RawEpisodeData.fromJson(json['raw']),
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': episodeResultSchemaVersion,
    'episodeId': episodeId,
    'taskId': taskId,
    'templateId': templateId,
    'split': split.jsonName,
    'condition': condition,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt.toIso8601String(),
    'validEpisode': validEpisode,
    'passed': passed,
    'agentClaimedSuccess': agentClaimedSuccess,
    'oracle': oracle.toJson(),
    'usage': usage.toJson(),
    'failure': failure?.toJson(),
    'metrics': Map<String, num>.from(metrics),
    'safetyGuardrails': safetyEvidence.toJson(),
    'raw': raw.toJson(),
  };
}
