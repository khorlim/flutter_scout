import 'dart:collection';

import 'benchmark_config.dart';
import 'catalog.dart';
import 'digests.dart';
import 'json_support.dart';
import 'task_manifest.dart';

const int benchmarkScheduleSchemaVersion = 1;

String computeCatalogSha256(CatalogSets catalog) {
  final manifests = [for (final entry in catalog.entries) entry.manifest]
    ..sort((first, second) => first.taskId.compareTo(second.taskId));
  return jsonSha256({
    'schemaVersion': taskManifestSchemaVersion,
    'tasks': [for (final manifest in manifests) manifest.toJson()],
  });
}

class BenchmarkConfigurationException implements Exception {
  BenchmarkConfigurationException(Iterable<String> issues)
    : issues = List<String>.unmodifiable(issues);

  final List<String> issues;

  @override
  String toString() => 'Invalid benchmark configuration: ${issues.join(' ')}';
}

class ScheduledEpisode {
  const ScheduledEpisode({
    required this.sequence,
    required this.episodeId,
    required this.pairId,
    required this.taskId,
    required this.templateId,
    required this.split,
    required this.variantSeed,
    required this.repetition,
    required this.repetitionSeed,
    required this.condition,
    required this.conditionOrder,
    required this.freshResetRequired,
  }) : assert(conditionOrder >= 1 && conditionOrder <= 4);

  final int sequence;
  final String episodeId;
  final String pairId;
  final String taskId;
  final String templateId;
  final BenchmarkSplit split;
  final int variantSeed;
  final int repetition;
  final int repetitionSeed;
  final String condition;
  final int conditionOrder;
  final bool freshResetRequired;

  factory ScheduledEpisode.fromJson(Object? value, int index) {
    final path = r'$.episodes[' + '$index]';
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'sequence',
      'episodeId',
      'pairId',
      'taskId',
      'templateId',
      'split',
      'variantSeed',
      'repetition',
      'repetitionSeed',
      'condition',
      'conditionOrder',
      'freshResetRequired',
    }, path);
    return ScheduledEpisode(
      sequence: expectJsonInt(json['sequence'], '$path.sequence', minimum: 1),
      episodeId: expectJsonString(json['episodeId'], '$path.episodeId'),
      pairId: expectJsonString(json['pairId'], '$path.pairId'),
      taskId: expectJsonString(json['taskId'], '$path.taskId'),
      templateId: expectJsonString(json['templateId'], '$path.templateId'),
      split: BenchmarkSplit.parse(json['split'], '$path.split'),
      variantSeed: expectJsonInt(json['variantSeed'], '$path.variantSeed'),
      repetition: expectJsonInt(
        json['repetition'],
        '$path.repetition',
        minimum: 1,
      ),
      repetitionSeed: expectJsonInt(
        json['repetitionSeed'],
        '$path.repetitionSeed',
        minimum: 0,
      ),
      condition: expectJsonString(json['condition'], '$path.condition'),
      conditionOrder: expectJsonInt(
        json['conditionOrder'],
        '$path.conditionOrder',
        minimum: 1,
      ),
      freshResetRequired: expectJsonBool(
        json['freshResetRequired'],
        '$path.freshResetRequired',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'episodeId': episodeId,
    'pairId': pairId,
    'taskId': taskId,
    'templateId': templateId,
    'split': split.jsonName,
    'variantSeed': variantSeed,
    'repetition': repetition,
    'repetitionSeed': repetitionSeed,
    'condition': condition,
    'conditionOrder': conditionOrder,
    'freshResetRequired': freshResetRequired,
  };
}

class BenchmarkSchedule {
  BenchmarkSchedule({
    required this.benchmarkId,
    required this.configSha256,
    required this.catalogSha256,
    required this.randomizationSeed,
    required this.repetitions,
    required Iterable<String> conditionIds,
    Map<String, ControlledComparisonRole>? conditionRoles,
    required Iterable<ScheduledEpisode> episodes,
  }) : conditionIds = List<String>.unmodifiable(conditionIds),
       conditionRoles = conditionRoles == null
           ? null
           : UnmodifiableMapView(
               Map<String, ControlledComparisonRole>.from(conditionRoles),
             ),
       episodes = List<ScheduledEpisode>.unmodifiable(episodes) {
    validateIdentifier(benchmarkId, 'benchmarkId');
    _validateSha256(configSha256, 'configSha256');
    _validateSha256(catalogSha256, 'catalogSha256');
    if (randomizationSeed < 0 || randomizationSeed > 0x7fffffff) {
      throw ArgumentError.value(randomizationSeed, 'randomizationSeed');
    }
    if (repetitions < 1) {
      throw ArgumentError.value(repetitions, 'repetitions');
    }
    if (this.conditionIds.toSet().length != this.conditionIds.length) {
      throw ArgumentError('Schedule condition ids must be unique.');
    }
    if (this.conditionRoles == null) {
      if (this.conditionIds.length != 2) {
        throw ArgumentError(
          'A legacy paired schedule requires two unique conditions.',
        );
      }
    } else {
      if (this.conditionIds.length < 3 || this.conditionIds.length > 4) {
        throw ArgumentError(
          'A controlled schedule requires three or four conditions.',
        );
      }
      if (this.conditionRoles!.keys.toSet().length !=
              this.conditionIds.length ||
          !this.conditionRoles!.keys.toSet().containsAll(this.conditionIds)) {
        throw ArgumentError(
          'Controlled schedule roles must map every condition exactly once.',
        );
      }
      final roles = this.conditionRoles!.values.toSet();
      const requiredRoles = {
        ControlledComparisonRole.screenshotCoordinateOnly,
        ControlledComparisonRole.currentReleasedScout,
        ControlledComparisonRole.candidateScout,
      };
      if (!roles.containsAll(requiredRoles) ||
          roles.length != this.conditionIds.length) {
        throw ArgumentError(
          'Controlled schedule roles must be unique and include screenshot, '
          'current, and candidate roles.',
        );
      }
    }
    for (final condition in this.conditionIds) {
      validateIdentifier(condition, 'conditionId');
    }
    if (this.episodes.isEmpty) {
      throw ArgumentError('A benchmark schedule must contain episodes.');
    }
    final episodeIds = <String>{};
    final sequences = <int>{};
    final pairs = <String, List<ScheduledEpisode>>{};
    for (final episode in this.episodes) {
      validateIdentifier(episode.episodeId, 'episodeId');
      validateIdentifier(episode.pairId, 'pairId');
      validateIdentifier(episode.taskId, 'taskId');
      validateIdentifier(episode.templateId, 'templateId');
      if (!episodeIds.add(episode.episodeId)) {
        throw ArgumentError(
          'Duplicate scheduled episode `${episode.episodeId}`.',
        );
      }
      if (!sequences.add(episode.sequence)) {
        throw ArgumentError(
          'Duplicate schedule sequence `${episode.sequence}`.',
        );
      }
      if (!this.conditionIds.contains(episode.condition)) {
        throw ArgumentError(
          'Unknown scheduled condition `${episode.condition}`.',
        );
      }
      if (!episode.freshResetRequired) {
        throw ArgumentError(
          'Every scheduled episode must require a fresh reset.',
        );
      }
      pairs.putIfAbsent(episode.pairId, () => []).add(episode);
    }
    final expectedSequences = {
      for (var sequence = 1; sequence <= this.episodes.length; sequence++)
        sequence,
    };
    if (sequences.length != expectedSequences.length ||
        !sequences.containsAll(expectedSequences)) {
      throw ArgumentError('Schedule sequences must be contiguous from one.');
    }
    for (final entry in pairs.entries) {
      final members = entry.value;
      if (members.length != this.conditionIds.length ||
          members.map((member) => member.condition).toSet().length !=
              this.conditionIds.length) {
        throw ArgumentError(
          'Comparison block `${entry.key}` must contain every condition.',
        );
      }
      final orders = members.map((member) => member.conditionOrder).toSet();
      final expectedOrders = {
        for (var order = 1; order <= this.conditionIds.length; order++) order,
      };
      if (orders.length != this.conditionIds.length ||
          !orders.containsAll(expectedOrders)) {
        throw ArgumentError(
          'Comparison block `${entry.key}` must use each condition order.',
        );
      }
      final bySequence = [...members]
        ..sort((first, second) => first.sequence.compareTo(second.sequence));
      for (var index = 0; index < bySequence.length; index++) {
        if (bySequence[index].conditionOrder != index + 1) {
          throw ArgumentError(
            'Comparison block `${entry.key}` condition order must match '
            'execution sequence.',
          );
        }
      }
      final anchor = members.first;
      final mismatched = members
          .skip(1)
          .any(
            (member) =>
                anchor.taskId != member.taskId ||
                anchor.templateId != member.templateId ||
                anchor.split != member.split ||
                anchor.variantSeed != member.variantSeed ||
                anchor.repetition != member.repetition ||
                anchor.repetitionSeed != member.repetitionSeed,
          );
      if (mismatched) {
        throw ArgumentError(
          'Comparison block `${entry.key}` does not share task and seeds.',
        );
      }
    }
  }

  final String benchmarkId;
  final String configSha256;
  final String catalogSha256;
  final int randomizationSeed;
  final int repetitions;
  final List<String> conditionIds;
  final Map<String, ControlledComparisonRole>? conditionRoles;
  final List<ScheduledEpisode> episodes;

  String get sha256 => jsonSha256(toJson());

  Map<String, ScheduledEpisode> get episodesById => UnmodifiableMapView({
    for (final episode in episodes) episode.episodeId: episode,
  });

  factory BenchmarkSchedule.generate({
    required BenchmarkConfig config,
    required CatalogSets catalog,
  }) {
    final catalogReport = const CatalogValidator().validate(catalog);
    catalogReport.throwIfInvalid();
    final actualCatalogSha = computeCatalogSha256(catalog);
    final issues = <String>[];
    if (config.catalogSha256 != actualCatalogSha) {
      issues.add(
        'catalogSha256 mismatch: config pins `${config.catalogSha256}` but '
        'loaded catalog is `$actualCatalogSha`.',
      );
    }
    final selected = [
      for (final entry in catalog.entries)
        if (config.includedSplits.contains(entry.bucket)) entry.manifest,
    ]..sort((first, second) => first.taskId.compareTo(second.taskId));
    if (selected.isEmpty) {
      issues.add('includedSplits select no catalog tasks.');
    }
    for (final task in selected) {
      final taskBudget = task.agentVisible.budget;
      if (taskBudget.maxActions != config.budget.maxActions ||
          taskBudget.maxWallTimeMs != config.budget.maxWallTimeMs ||
          taskBudget.maxTokens != config.budget.maxTokens) {
        issues.add(
          'Task `${task.taskId}` budget does not exactly match the pinned '
          'benchmark action, wall-time, and token budgets.',
        );
      }
    }
    final selectedTemplates = selected.map((item) => item.templateId).toSet();
    final configuredTemplates = config.templateFamilyByTemplateId.keys.toSet();
    final missingFamilies =
        selectedTemplates.difference(configuredTemplates).toList()..sort();
    final extraFamilies =
        configuredTemplates.difference(selectedTemplates).toList()..sort();
    if (missingFamilies.isNotEmpty) {
      issues.add(
        'Selected templates without a family: ${missingFamilies.join(', ')}.',
      );
    }
    if (extraFamilies.isNotEmpty) {
      issues.add(
        'Family mapping contains unselected templates: ${extraFamilies.join(', ')}.',
      );
    }
    if (issues.isNotEmpty) throw BenchmarkConfigurationException(issues);

    final plans = <_PairPlan>[
      for (final task in selected)
        for (var repetition = 1; repetition <= config.repetitions; repetition++)
          _PairPlan(task: task, repetition: repetition),
    ];
    final random = _StableRandom(config.randomizationSeed);
    _shuffle(plans, random);
    final controlled = config.controlledComparison != null;
    final currentFirst = <bool>[];
    final controlledBase = <String>[];
    final controlledRotations = <int>[];
    if (controlled) {
      controlledBase.addAll(config.conditionIds);
      _shuffle(controlledBase, random);
      controlledRotations.addAll([
        for (var index = 0; index < plans.length; index++)
          index % controlledBase.length,
      ]);
      _shuffle(controlledRotations, random);
    } else {
      final extraCurrentFirst = random.nextInt(2).isEven;
      currentFirst.addAll([
        for (var index = 0; index < plans.length; index++)
          index.isEven ? extraCurrentFirst : !extraCurrentFirst,
      ]);
      _shuffle(currentFirst, random);
    }

    final episodes = <ScheduledEpisode>[];
    var sequence = 1;
    for (var index = 0; index < plans.length; index++) {
      final plan = plans[index];
      final task = plan.task;
      final pairId = '${config.benchmarkId}.${task.taskId}.r${plan.repetition}';
      final conditions = controlled
          ? [
              for (var order = 0; order < controlledBase.length; order++)
                controlledBase[(order + controlledRotations[index]) %
                    controlledBase.length],
            ]
          : currentFirst[index]
          ? config.conditionIds
          : config.conditionIds.reversed.toList();
      final repetitionSeed = _deriveSeed(
        config.randomizationSeed,
        task.taskId,
        task.variant.seed,
        plan.repetition,
      );
      for (var order = 0; order < conditions.length; order++) {
        final condition = conditions[order];
        episodes.add(
          ScheduledEpisode(
            sequence: sequence++,
            episodeId: '$pairId.$condition',
            pairId: pairId,
            taskId: task.taskId,
            templateId: task.templateId,
            split: task.split,
            variantSeed: task.variant.seed,
            repetition: plan.repetition,
            repetitionSeed: repetitionSeed,
            condition: condition,
            conditionOrder: order + 1,
            freshResetRequired: true,
          ),
        );
      }
    }
    return BenchmarkSchedule(
      benchmarkId: config.benchmarkId,
      configSha256: config.sha256,
      catalogSha256: actualCatalogSha,
      randomizationSeed: config.randomizationSeed,
      repetitions: config.repetitions,
      conditionIds: config.conditionIds,
      conditionRoles: config.conditionRoles,
      episodes: episodes,
    );
  }

  factory BenchmarkSchedule.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$');
    rejectUnknownKeys(json, const {
      'schemaVersion',
      'benchmarkId',
      'configSha256',
      'catalogSha256',
      'randomizationSeed',
      'repetitions',
      'conditionIds',
      'conditionRoles',
      'episodes',
    }, r'$');
    final version = expectJsonInt(json['schemaVersion'], r'$.schemaVersion');
    if (version != benchmarkScheduleSchemaVersion) {
      throw FormatException(
        'Unsupported benchmark schedule schemaVersion $version; expected '
        '$benchmarkScheduleSchemaVersion.',
      );
    }
    final rawConditions = expectJsonList(
      json['conditionIds'],
      r'$.conditionIds',
    );
    final rawEpisodes = expectJsonList(json['episodes'], r'$.episodes');
    final rawRoles = json['conditionRoles'] == null
        ? null
        : expectJsonObject(json['conditionRoles'], r'$.conditionRoles');
    return BenchmarkSchedule(
      benchmarkId: expectJsonString(json['benchmarkId'], r'$.benchmarkId'),
      configSha256: expectJsonString(json['configSha256'], r'$.configSha256'),
      catalogSha256: expectJsonString(
        json['catalogSha256'],
        r'$.catalogSha256',
      ),
      randomizationSeed: expectJsonInt(
        json['randomizationSeed'],
        r'$.randomizationSeed',
        minimum: 0,
      ),
      repetitions: expectJsonInt(
        json['repetitions'],
        r'$.repetitions',
        minimum: 1,
      ),
      conditionIds: [
        for (var index = 0; index < rawConditions.length; index++)
          expectJsonString(
            rawConditions[index],
            r'$.conditionIds[' + '$index]',
          ),
      ],
      conditionRoles: rawRoles == null
          ? null
          : {
              for (final entry in rawRoles.entries)
                entry.key: ControlledComparisonRole.parse(
                  entry.value,
                  r'$.conditionRoles.' + entry.key,
                ),
            },
      episodes: [
        for (var index = 0; index < rawEpisodes.length; index++)
          ScheduledEpisode.fromJson(rawEpisodes[index], index),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': benchmarkScheduleSchemaVersion,
    'benchmarkId': benchmarkId,
    'configSha256': configSha256,
    'catalogSha256': catalogSha256,
    'randomizationSeed': randomizationSeed,
    'repetitions': repetitions,
    'conditionIds': conditionIds,
    if (conditionRoles != null)
      'conditionRoles': {
        for (final conditionId in conditionIds)
          conditionId: conditionRoles![conditionId]!.jsonName,
      },
    'episodes': [for (final episode in episodes) episode.toJson()],
  };
}

class _PairPlan {
  const _PairPlan({required this.task, required this.repetition});

  final TaskManifest task;
  final int repetition;
}

class _StableRandom {
  _StableRandom(int seed) : _state = seed & 0xffffffff;

  int _state;

  int nextInt(int upperBound) {
    if (upperBound <= 0) throw ArgumentError.value(upperBound, 'upperBound');
    _state = (1664525 * _state + 1013904223) & 0xffffffff;
    return _state % upperBound;
  }
}

void _shuffle<T>(List<T> values, _StableRandom random) {
  for (var index = values.length - 1; index > 0; index--) {
    final other = random.nextInt(index + 1);
    final value = values[index];
    values[index] = values[other];
    values[other] = value;
  }
}

int _deriveSeed(
  int benchmarkSeed,
  String taskId,
  int variantSeed,
  int repetition,
) {
  var hash = 2166136261;
  final text = '$benchmarkSeed|$taskId|$variantSeed|$repetition';
  for (final codeUnit in text.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 16777619) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

void _validateSha256(String value, String path) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw FormatException('$path must be a lowercase SHA-256 digest.');
  }
}
