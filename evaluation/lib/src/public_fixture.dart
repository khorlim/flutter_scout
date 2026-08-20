import 'dart:collection';

import 'corpus.dart';
import 'json_support.dart';
import 'task_manifest.dart';

const int publicFixtureConfigurationSchemaVersion = 1;
const String publicFixtureParameterKey = 'publicFixture';
const String publicFixtureOracleId = 'oracle.public-fixture-v1';
const String publicFixtureSetupFixture = 'setup.public-fixture-reset-v1';
const String publicFixtureTeardownFixture = 'teardown.public-fixture-reset-v1';
const String publicFixtureRevision = 'public-fixture-v1';

/// Evaluator-only configuration for one deterministic Stress Lab fixture.
///
/// The complete value belongs in [TaskVariant.parameters]. Only the task's
/// natural-language instruction is projected to an agent. In particular, the
/// opaque completion value and predicate identifiers never cross that
/// boundary.
class PublicFixtureConfiguration {
  PublicFixtureConfiguration({
    required this.taskId,
    required this.templateId,
    required this.variantId,
    required this.seed,
    required this.family,
    required this.patternId,
    required this.title,
    required this.targetLabel,
    required this.decoyLabel,
    required this.inputLabel,
    required this.inputValue,
    required this.completionValue,
    required this.contentLength,
    required this.targetIndex,
    required this.initialPage,
    required this.delayMs,
    required this.initialModalOpen,
    required this.initialFocus,
    required this.labelOnlyTarget,
    required this.successPredicateId,
    required this.forbiddenPredicateId,
    required Map<String, String> perturbations,
  }) : perturbations = UnmodifiableMapView(
         Map<String, String>.from(perturbations),
       ) {
    validateIdentifier(taskId, 'taskId');
    validateIdentifier(templateId, 'templateId');
    validateIdentifier(variantId, 'variantId');
    validateIdentifier(patternId, 'patternId');
    validateIdentifier(successPredicateId, 'successPredicateId');
    validateIdentifier(forbiddenPredicateId, 'forbiddenPredicateId');
    if (taskId != '$templateId.$variantId' ||
        patternId != templateId ||
        !RegExp(r'^variant-[1-5]$').hasMatch(variantId) ||
        seed <= 0 ||
        seed > 1000000000 ||
        completionValue != 'fixture-complete.$taskId.$seed' ||
        successPredicateId != 'predicate.$taskId.completed' ||
        forbiddenPredicateId != 'predicate.$taskId.forbidden') {
      throw const FormatException(
        'The public fixture identity fields are inconsistent.',
      );
    }
    for (final entry in <String, String>{
      'title': title,
      'targetLabel': targetLabel,
      'decoyLabel': decoyLabel,
      'inputLabel': inputLabel,
      'inputValue': inputValue,
      'completionValue': completionValue,
    }.entries) {
      if (entry.value.trim().isEmpty || entry.value.length > 160) {
        throw ArgumentError.value(
          entry.value,
          entry.key,
          'must be non-empty and at most 160 characters',
        );
      }
    }
    if (contentLength < 8 || contentLength > 120) {
      throw ArgumentError.value(contentLength, 'contentLength');
    }
    if (targetIndex < 0 || targetIndex >= contentLength) {
      throw ArgumentError.value(targetIndex, 'targetIndex');
    }
    if (initialPage < 0 || initialPage > 2) {
      throw ArgumentError.value(initialPage, 'initialPage');
    }
    if (delayMs < 0 || delayMs > 2000) {
      throw ArgumentError.value(delayMs, 'delayMs');
    }
    if (this.perturbations.isEmpty ||
        this.perturbations.length > PerturbationDimension.values.length) {
      throw ArgumentError.value(perturbations, 'perturbations');
    }
    for (final entry in this.perturbations.entries) {
      PerturbationDimension.parse(entry.key, 'perturbations.${entry.key}');
      if (entry.value.trim().isEmpty || entry.value.length > 96) {
        throw ArgumentError.value(entry.value, 'perturbations.${entry.key}');
      }
    }
  }

  final String taskId;
  final String templateId;
  final String variantId;
  final int seed;
  final CorpusTaskFamily family;
  final String patternId;
  final String title;
  final String targetLabel;
  final String decoyLabel;
  final String inputLabel;
  final String inputValue;
  final String completionValue;
  final int contentLength;
  final int targetIndex;
  final int initialPage;
  final int delayMs;
  final bool initialModalOpen;
  final bool initialFocus;
  final bool labelOnlyTarget;
  final String successPredicateId;
  final String forbiddenPredicateId;
  final Map<String, String> perturbations;

  factory PublicFixtureConfiguration.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$.publicFixture');
    rejectUnknownKeys(json, const <String>{
      'schemaVersion',
      'revision',
      'taskId',
      'templateId',
      'variantId',
      'seed',
      'family',
      'patternId',
      'title',
      'targetLabel',
      'decoyLabel',
      'inputLabel',
      'inputValue',
      'completionValue',
      'contentLength',
      'targetIndex',
      'initialPage',
      'delayMs',
      'initialModalOpen',
      'initialFocus',
      'labelOnlyTarget',
      'successPredicateId',
      'forbiddenPredicateId',
      'perturbations',
    }, r'$.publicFixture');
    final version = expectJsonInt(
      json['schemaVersion'],
      r'$.publicFixture.schemaVersion',
    );
    if (version != publicFixtureConfigurationSchemaVersion ||
        json['revision'] != publicFixtureRevision) {
      throw const FormatException(
        'The public fixture configuration version is unsupported.',
      );
    }
    final rawPerturbations = expectJsonObject(
      json['perturbations'],
      r'$.publicFixture.perturbations',
    );
    return PublicFixtureConfiguration(
      taskId: expectJsonString(json['taskId'], r'$.publicFixture.taskId'),
      templateId: expectJsonString(
        json['templateId'],
        r'$.publicFixture.templateId',
      ),
      variantId: expectJsonString(
        json['variantId'],
        r'$.publicFixture.variantId',
      ),
      seed: expectJsonInt(json['seed'], r'$.publicFixture.seed'),
      family: CorpusTaskFamily.parse(json['family'], r'$.publicFixture.family'),
      patternId: expectJsonString(
        json['patternId'],
        r'$.publicFixture.patternId',
      ),
      title: expectJsonString(json['title'], r'$.publicFixture.title'),
      targetLabel: expectJsonString(
        json['targetLabel'],
        r'$.publicFixture.targetLabel',
      ),
      decoyLabel: expectJsonString(
        json['decoyLabel'],
        r'$.publicFixture.decoyLabel',
      ),
      inputLabel: expectJsonString(
        json['inputLabel'],
        r'$.publicFixture.inputLabel',
      ),
      inputValue: expectJsonString(
        json['inputValue'],
        r'$.publicFixture.inputValue',
      ),
      completionValue: expectJsonString(
        json['completionValue'],
        r'$.publicFixture.completionValue',
      ),
      contentLength: expectJsonInt(
        json['contentLength'],
        r'$.publicFixture.contentLength',
        minimum: 8,
      ),
      targetIndex: expectJsonInt(
        json['targetIndex'],
        r'$.publicFixture.targetIndex',
        minimum: 0,
      ),
      initialPage: expectJsonInt(
        json['initialPage'],
        r'$.publicFixture.initialPage',
        minimum: 0,
      ),
      delayMs: expectJsonInt(
        json['delayMs'],
        r'$.publicFixture.delayMs',
        minimum: 0,
      ),
      initialModalOpen: expectJsonBool(
        json['initialModalOpen'],
        r'$.publicFixture.initialModalOpen',
      ),
      initialFocus: expectJsonBool(
        json['initialFocus'],
        r'$.publicFixture.initialFocus',
      ),
      labelOnlyTarget: expectJsonBool(
        json['labelOnlyTarget'],
        r'$.publicFixture.labelOnlyTarget',
      ),
      successPredicateId: expectJsonString(
        json['successPredicateId'],
        r'$.publicFixture.successPredicateId',
      ),
      forbiddenPredicateId: expectJsonString(
        json['forbiddenPredicateId'],
        r'$.publicFixture.forbiddenPredicateId',
      ),
      perturbations: <String, String>{
        for (final entry in rawPerturbations.entries)
          entry.key: expectJsonString(
            entry.value,
            r'$.publicFixture.perturbations.' + entry.key,
          ),
      },
    );
  }

  factory PublicFixtureConfiguration.fromManifest(TaskManifest manifest) {
    if (manifest.hiddenHarness.oracleId != publicFixtureOracleId) {
      throw ArgumentError.value(
        manifest.hiddenHarness.oracleId,
        'manifest',
        'does not select the public fixture oracle',
      );
    }
    final configuration = PublicFixtureConfiguration.fromJson(
      manifest.variant.parameters[publicFixtureParameterKey],
    );
    if (configuration.taskId != manifest.taskId ||
        configuration.templateId != manifest.templateId ||
        configuration.variantId != manifest.variant.variantId ||
        configuration.seed != manifest.variant.seed ||
        manifest.hiddenHarness.setupFixture != publicFixtureSetupFixture ||
        manifest.hiddenHarness.teardownFixture !=
            publicFixtureTeardownFixture ||
        manifest.hiddenHarness.successPredicateIds.length != 1 ||
        manifest.hiddenHarness.successPredicateIds.single !=
            configuration.successPredicateId ||
        manifest.hiddenHarness.forbiddenPredicateIds.length != 1 ||
        manifest.hiddenHarness.forbiddenPredicateIds.single !=
            configuration.forbiddenPredicateId) {
      throw const FormatException(
        'The public fixture configuration does not match its manifest.',
      );
    }
    return configuration;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': publicFixtureConfigurationSchemaVersion,
    'revision': publicFixtureRevision,
    'taskId': taskId,
    'templateId': templateId,
    'variantId': variantId,
    'seed': seed,
    'family': family.jsonName,
    'patternId': patternId,
    'title': title,
    'targetLabel': targetLabel,
    'decoyLabel': decoyLabel,
    'inputLabel': inputLabel,
    'inputValue': inputValue,
    'completionValue': completionValue,
    'contentLength': contentLength,
    'targetIndex': targetIndex,
    'initialPage': initialPage,
    'delayMs': delayMs,
    'initialModalOpen': initialModalOpen,
    'initialFocus': initialFocus,
    'labelOnlyTarget': labelOnlyTarget,
    'successPredicateId': successPredicateId,
    'forbiddenPredicateId': forbiddenPredicateId,
    'perturbations': Map<String, String>.from(perturbations),
  };
}
