import 'dart:collection';

import 'catalog.dart';
import 'json_support.dart';
import 'task_manifest.dart';

const int corpusPolicySchemaVersion = 1;
const int corpusDescriptorSchemaVersion = 1;
const int corpusValidationReportSchemaVersion = 1;
const int goldMinimumTemplateCount = 60;
const int goldMinimumVariantsPerTemplate = 5;
const int goldMinimumRealAppIdentitiesBeyondStressLab = 2;
const String goldStressLabAppId = 'flutter-scout-stress-lab';

enum CorpusTaskFamily {
  forms('forms'),
  lists('lists'),
  grids('grids'),
  nestedScroll('nested_scroll'),
  tabs('tabs'),
  dialogsSheetsMenus('dialogs_sheets_menus'),
  pickers('pickers'),
  customPainted('custom_painted'),
  gesture('gesture'),
  lifecycleReconnect('lifecycle_reconnect'),
  faults('faults'),
  securityPrivacy('security_privacy');

  const CorpusTaskFamily(this.jsonName);

  final String jsonName;

  static CorpusTaskFamily parse(Object? value, String path) {
    for (final family in values) {
      if (value == family.jsonName) return family;
    }
    throw FormatException(
      '$path must be one of '
      '${values.map((value) => value.jsonName).join(', ')}.',
    );
  }
}

enum PerturbationDimension {
  viewport('viewport'),
  devicePixelRatio('device_pixel_ratio'),
  orientation('orientation'),
  contentOrder('content_order'),
  contentLength('content_length'),
  initialScrollState('initial_scroll_state'),
  initialTabState('initial_tab_state'),
  initialModalState('initial_modal_state'),
  initialFocusState('initial_focus_state'),
  animationDelay('animation_delay'),
  networkDelay('network_delay'),
  semanticsDegradation('semantics_degradation'),
  keyDegradation('key_degradation');

  const PerturbationDimension(this.jsonName);

  final String jsonName;

  static PerturbationDimension parse(Object? value, String path) {
    for (final dimension in values) {
      if (value == dimension.jsonName) return dimension;
    }
    throw FormatException(
      '$path must be one of '
      '${values.map((value) => value.jsonName).join(', ')}.',
    );
  }
}

enum CorpusAppKind {
  stressLab('stress_lab'),
  realApplication('real_application');

  const CorpusAppKind(this.jsonName);

  final String jsonName;

  static CorpusAppKind parse(Object? value, String path) {
    for (final kind in values) {
      if (value == kind.jsonName) return kind;
    }
    throw FormatException(
      '$path must be one of '
      '${values.map((value) => value.jsonName).join(', ')}.',
    );
  }
}

class CorpusAppIdentity {
  CorpusAppIdentity({
    required this.appId,
    required this.displayName,
    required this.kind,
    required this.source,
    required this.revision,
  }) {
    validateIdentifier(appId, 'appId');
    if (displayName.trim().isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'must not be empty',
      );
    }
    if (source.trim().isEmpty) {
      throw ArgumentError.value(source, 'source', 'must not be empty');
    }
    if (revision.trim().isEmpty) {
      throw ArgumentError.value(revision, 'revision', 'must not be empty');
    }
  }

  final String appId;
  final String displayName;
  final CorpusAppKind kind;
  final String source;
  final String revision;

  factory CorpusAppIdentity.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'appId',
      'displayName',
      'kind',
      'source',
      'revision',
    }, path);
    return CorpusAppIdentity(
      appId: expectJsonString(json['appId'], '$path.appId'),
      displayName: expectJsonString(json['displayName'], '$path.displayName'),
      kind: CorpusAppKind.parse(json['kind'], '$path.kind'),
      source: expectJsonString(json['source'], '$path.source'),
      revision: expectJsonString(json['revision'], '$path.revision'),
    );
  }

  Map<String, Object?> toJson() => {
    'appId': appId,
    'displayName': displayName,
    'kind': kind.jsonName,
    'source': source,
    'revision': revision,
  };

  String get canonicalIdentity => '$appId|${kind.jsonName}|$source|$revision';
}

class CorpusVariantDescriptor {
  CorpusVariantDescriptor({
    required this.taskId,
    required this.variantId,
    required this.semanticsPreserving,
    required Iterable<PerturbationDimension> perturbationDimensions,
  }) : perturbationDimensions = List<PerturbationDimension>.unmodifiable(
         perturbationDimensions,
       ) {
    validateIdentifier(taskId, 'taskId');
    validateIdentifier(variantId, 'variantId');
    _rejectDuplicates(
      this.perturbationDimensions.map((value) => value.jsonName),
      'perturbationDimensions',
    );
    if (this.perturbationDimensions.isEmpty) {
      throw ArgumentError.value(
        perturbationDimensions,
        'perturbationDimensions',
        'must not be empty',
      );
    }
  }

  final String taskId;
  final String variantId;
  final bool semanticsPreserving;
  final List<PerturbationDimension> perturbationDimensions;

  factory CorpusVariantDescriptor.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'taskId',
      'variantId',
      'semanticsPreserving',
      'perturbationDimensions',
    }, path);
    final rawDimensions = expectJsonList(
      json['perturbationDimensions'],
      '$path.perturbationDimensions',
    );
    return CorpusVariantDescriptor(
      taskId: expectJsonString(json['taskId'], '$path.taskId'),
      variantId: expectJsonString(json['variantId'], '$path.variantId'),
      semanticsPreserving: expectJsonBool(
        json['semanticsPreserving'],
        '$path.semanticsPreserving',
      ),
      perturbationDimensions: [
        for (var index = 0; index < rawDimensions.length; index++)
          PerturbationDimension.parse(
            rawDimensions[index],
            '$path.perturbationDimensions[$index]',
          ),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'taskId': taskId,
    'variantId': variantId,
    'semanticsPreserving': semanticsPreserving,
    'perturbationDimensions': [
      for (final dimension in perturbationDimensions) dimension.jsonName,
    ],
  };
}

class CorpusTemplateDescriptor {
  CorpusTemplateDescriptor({
    required this.templateId,
    required this.app,
    required Iterable<CorpusTaskFamily> families,
    required Iterable<CorpusVariantDescriptor> variants,
  }) : families = List<CorpusTaskFamily>.unmodifiable(families),
       variants = List<CorpusVariantDescriptor>.unmodifiable(variants) {
    validateIdentifier(templateId, 'templateId');
    _rejectDuplicates(this.families.map((value) => value.jsonName), 'families');
    if (this.families.isEmpty) {
      throw ArgumentError.value(families, 'families', 'must not be empty');
    }
    if (this.variants.isEmpty) {
      throw ArgumentError.value(variants, 'variants', 'must not be empty');
    }
  }

  final String templateId;
  final CorpusAppIdentity app;
  final List<CorpusTaskFamily> families;
  final List<CorpusVariantDescriptor> variants;

  factory CorpusTemplateDescriptor.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'templateId',
      'app',
      'families',
      'variants',
    }, path);
    final rawFamilies = expectJsonList(json['families'], '$path.families');
    final rawVariants = expectJsonList(json['variants'], '$path.variants');
    return CorpusTemplateDescriptor(
      templateId: expectJsonString(json['templateId'], '$path.templateId'),
      app: CorpusAppIdentity.fromJson(json['app'], '$path.app'),
      families: [
        for (var index = 0; index < rawFamilies.length; index++)
          CorpusTaskFamily.parse(rawFamilies[index], '$path.families[$index]'),
      ],
      variants: [
        for (var index = 0; index < rawVariants.length; index++)
          CorpusVariantDescriptor.fromJson(
            rawVariants[index],
            '$path.variants[$index]',
          ),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'templateId': templateId,
    'app': app.toJson(),
    'families': [for (final family in families) family.jsonName],
    'variants': [for (final variant in variants) variant.toJson()],
  };
}

class CorpusDescriptor {
  CorpusDescriptor({
    required this.corpusId,
    required this.corpusVersion,
    required Iterable<CorpusTemplateDescriptor> templates,
  }) : templates = List<CorpusTemplateDescriptor>.unmodifiable(templates) {
    validateIdentifier(corpusId, 'corpusId');
    if (corpusVersion.trim().isEmpty) {
      throw ArgumentError.value(
        corpusVersion,
        'corpusVersion',
        'must not be empty',
      );
    }
  }

  final String corpusId;
  final String corpusVersion;
  final List<CorpusTemplateDescriptor> templates;

  factory CorpusDescriptor.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$');
    rejectUnknownKeys(json, const {
      'schemaVersion',
      'corpusId',
      'corpusVersion',
      'templates',
    }, r'$');
    final version = expectJsonInt(json['schemaVersion'], r'$.schemaVersion');
    if (version != corpusDescriptorSchemaVersion) {
      throw FormatException(
        'Unsupported corpus descriptor schemaVersion $version; expected '
        '$corpusDescriptorSchemaVersion.',
      );
    }
    final rawTemplates = expectJsonList(json['templates'], r'$.templates');
    if (rawTemplates.isEmpty) {
      throw const FormatException(r'$.templates must not be empty.');
    }
    return CorpusDescriptor(
      corpusId: expectJsonString(json['corpusId'], r'$.corpusId'),
      corpusVersion: expectJsonString(
        json['corpusVersion'],
        r'$.corpusVersion',
      ),
      templates: [
        for (var index = 0; index < rawTemplates.length; index++)
          CorpusTemplateDescriptor.fromJson(
            rawTemplates[index],
            r'$.templates['
            '$index]',
          ),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': corpusDescriptorSchemaVersion,
    'corpusId': corpusId,
    'corpusVersion': corpusVersion,
    'templates': [for (final template in templates) template.toJson()],
  };
}

class CorpusPolicy {
  CorpusPolicy({
    required this.policyId,
    required this.minimumTemplateCount,
    required this.minimumVariantsPerTemplate,
    required this.minimumTemplatesPerRequiredFamily,
    required this.minimumRealAppIdentitiesBeyondStressLab,
    required Iterable<CorpusTaskFamily> requiredFamilies,
    required Iterable<PerturbationDimension> requiredPerturbationDimensions,
    required Iterable<BenchmarkSplit> requiredSplits,
    required Iterable<String> stressLabAppIds,
  }) : requiredFamilies = List<CorpusTaskFamily>.unmodifiable(requiredFamilies),
       requiredPerturbationDimensions =
           List<PerturbationDimension>.unmodifiable(
             requiredPerturbationDimensions,
           ),
       requiredSplits = List<BenchmarkSplit>.unmodifiable(requiredSplits),
       stressLabAppIds = List<String>.unmodifiable(stressLabAppIds) {
    validateIdentifier(policyId, 'policyId');
    if (minimumTemplateCount < 1 ||
        minimumVariantsPerTemplate < 1 ||
        minimumTemplatesPerRequiredFamily < 1 ||
        minimumRealAppIdentitiesBeyondStressLab < 1) {
      throw ArgumentError('Corpus policy minimums must all be positive.');
    }
    _rejectDuplicates(
      this.requiredFamilies.map((value) => value.jsonName),
      'requiredFamilies',
    );
    _rejectDuplicates(
      this.requiredPerturbationDimensions.map((value) => value.jsonName),
      'requiredPerturbationDimensions',
    );
    _rejectDuplicates(
      this.requiredSplits.map((value) => value.jsonName),
      'requiredSplits',
    );
    _rejectDuplicates(this.stressLabAppIds, 'stressLabAppIds');
    if (this.requiredFamilies.isEmpty ||
        this.requiredPerturbationDimensions.isEmpty ||
        this.requiredSplits.isEmpty ||
        this.stressLabAppIds.isEmpty) {
      throw ArgumentError('Corpus policy requirement lists must not be empty.');
    }
    for (final appId in this.stressLabAppIds) {
      validateIdentifier(appId, 'stressLabAppIds');
    }
  }

  final String policyId;
  final int minimumTemplateCount;
  final int minimumVariantsPerTemplate;
  final int minimumTemplatesPerRequiredFamily;
  final int minimumRealAppIdentitiesBeyondStressLab;
  final List<CorpusTaskFamily> requiredFamilies;
  final List<PerturbationDimension> requiredPerturbationDimensions;
  final List<BenchmarkSplit> requiredSplits;
  final List<String> stressLabAppIds;

  factory CorpusPolicy.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$');
    rejectUnknownKeys(json, const {
      r'$schema',
      'schemaVersion',
      'policyId',
      'minimumTemplateCount',
      'minimumVariantsPerTemplate',
      'minimumTemplatesPerRequiredFamily',
      'minimumRealAppIdentitiesBeyondStressLab',
      'requiredFamilies',
      'requiredPerturbationDimensions',
      'requiredSplits',
      'stressLabAppIds',
    }, r'$');
    final version = expectJsonInt(json['schemaVersion'], r'$.schemaVersion');
    if (version != corpusPolicySchemaVersion) {
      throw FormatException(
        'Unsupported corpus policy schemaVersion $version; expected '
        '$corpusPolicySchemaVersion.',
      );
    }

    List<T> parseList<T>(
      String name,
      T Function(Object? value, String path) parse,
    ) {
      final values = expectJsonList(json[name], r'$.' + name);
      return [
        for (var index = 0; index < values.length; index++)
          parse(values[index], r'$.' + '$name[$index]'),
      ];
    }

    return CorpusPolicy(
      policyId: expectJsonString(json['policyId'], r'$.policyId'),
      minimumTemplateCount: expectJsonInt(
        json['minimumTemplateCount'],
        r'$.minimumTemplateCount',
        minimum: 1,
      ),
      minimumVariantsPerTemplate: expectJsonInt(
        json['minimumVariantsPerTemplate'],
        r'$.minimumVariantsPerTemplate',
        minimum: 1,
      ),
      minimumTemplatesPerRequiredFamily: expectJsonInt(
        json['minimumTemplatesPerRequiredFamily'],
        r'$.minimumTemplatesPerRequiredFamily',
        minimum: 1,
      ),
      minimumRealAppIdentitiesBeyondStressLab: expectJsonInt(
        json['minimumRealAppIdentitiesBeyondStressLab'],
        r'$.minimumRealAppIdentitiesBeyondStressLab',
        minimum: 1,
      ),
      requiredFamilies: parseList('requiredFamilies', CorpusTaskFamily.parse),
      requiredPerturbationDimensions: parseList(
        'requiredPerturbationDimensions',
        PerturbationDimension.parse,
      ),
      requiredSplits: parseList('requiredSplits', BenchmarkSplit.parse),
      stressLabAppIds: parseList(
        'stressLabAppIds',
        (value, path) => expectJsonString(value, path),
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': corpusPolicySchemaVersion,
    'policyId': policyId,
    'minimumTemplateCount': minimumTemplateCount,
    'minimumVariantsPerTemplate': minimumVariantsPerTemplate,
    'minimumTemplatesPerRequiredFamily': minimumTemplatesPerRequiredFamily,
    'minimumRealAppIdentitiesBeyondStressLab':
        minimumRealAppIdentitiesBeyondStressLab,
    'requiredFamilies': [
      for (final family in requiredFamilies) family.jsonName,
    ],
    'requiredPerturbationDimensions': [
      for (final dimension in requiredPerturbationDimensions)
        dimension.jsonName,
    ],
    'requiredSplits': [for (final split in requiredSplits) split.jsonName],
    'stressLabAppIds': stressLabAppIds,
  };
}

enum CorpusIssueSeverity {
  invalid('invalid'),
  releaseBlocker('release_blocker');

  const CorpusIssueSeverity(this.jsonName);

  final String jsonName;
}

class CorpusIssue {
  const CorpusIssue({
    required this.code,
    required this.severity,
    required this.message,
    this.templateId,
    this.taskId,
  });

  final String code;
  final CorpusIssueSeverity severity;
  final String message;
  final String? templateId;
  final String? taskId;

  Map<String, Object?> toJson() => {
    'code': code,
    'severity': severity.jsonName,
    'message': message,
    if (templateId != null) 'templateId': templateId,
    if (taskId != null) 'taskId': taskId,
  };
}

class CorpusValidationReport {
  CorpusValidationReport({
    required Iterable<CorpusIssue> issues,
    required this.taskCount,
    required this.templateCount,
    required this.descriptorTemplateCount,
    required this.appIdentityCount,
    required this.realApplicationIdentityCount,
    required Map<String, int> splitTemplateCounts,
    required Map<String, int> familyTemplateCounts,
  }) : issues = List<CorpusIssue>.unmodifiable(issues),
       splitTemplateCounts = UnmodifiableMapView(
         Map<String, int>.from(splitTemplateCounts),
       ),
       familyTemplateCounts = UnmodifiableMapView(
         Map<String, int>.from(familyTemplateCounts),
       );

  final List<CorpusIssue> issues;
  final int taskCount;
  final int templateCount;
  final int descriptorTemplateCount;
  final int appIdentityCount;
  final int realApplicationIdentityCount;
  final Map<String, int> splitTemplateCounts;
  final Map<String, int> familyTemplateCounts;

  bool get isValid =>
      !issues.any((issue) => issue.severity == CorpusIssueSeverity.invalid);

  bool get releaseEligible => isValid && issues.isEmpty;

  Map<String, Object?> toJson() => {
    'schemaVersion': corpusValidationReportSchemaVersion,
    'valid': isValid,
    'releaseEligible': releaseEligible,
    'taskCount': taskCount,
    'templateCount': templateCount,
    'descriptorTemplateCount': descriptorTemplateCount,
    'appIdentityCount': appIdentityCount,
    'realApplicationIdentityCount': realApplicationIdentityCount,
    'splitTemplateCounts': splitTemplateCounts,
    'familyTemplateCounts': familyTemplateCounts,
    'issues': [for (final issue in issues) issue.toJson()],
  };
}

class CorpusValidator {
  const CorpusValidator();

  CorpusValidationReport validate({
    required CatalogSets catalog,
    required CorpusDescriptor descriptor,
    required CorpusPolicy policy,
  }) {
    final issues = <CorpusIssue>[];
    _validateGoldPolicyFloor(policy, issues);
    final manifestsByTask = <String, TaskManifest>{};
    final manifestsByTemplate = <String, List<TaskManifest>>{};
    final splitTemplates = <BenchmarkSplit, Set<String>>{
      for (final split in BenchmarkSplit.values) split: <String>{},
    };

    final catalogReport = const CatalogValidator().validate(catalog);
    for (final issue in catalogReport.issues) {
      issues.add(
        CorpusIssue(
          code: 'catalog_${issue.code}',
          severity: CorpusIssueSeverity.invalid,
          message: issue.message,
          templateId: issue.templateId,
          taskId: issue.taskId,
        ),
      );
    }
    for (final entry in catalog.entries) {
      final manifest = entry.manifest;
      manifestsByTask.putIfAbsent(manifest.taskId, () => manifest);
      manifestsByTemplate
          .putIfAbsent(manifest.templateId, () => [])
          .add(manifest);
      splitTemplates[entry.bucket]!.add(manifest.templateId);
    }

    final descriptorsByTemplate = <String, CorpusTemplateDescriptor>{};
    final describedTaskIds = <String, String>{};
    final appIdentities = <String, CorpusAppIdentity>{};
    final familyTemplates = <CorpusTaskFamily, Set<String>>{
      for (final family in CorpusTaskFamily.values) family: <String>{},
    };

    for (final template in descriptor.templates) {
      final previousTemplate = descriptorsByTemplate[template.templateId];
      if (previousTemplate != null) {
        issues.add(
          CorpusIssue(
            code: 'duplicate_template_descriptor',
            severity: CorpusIssueSeverity.invalid,
            message:
                'Template `${template.templateId}` has more than one corpus '
                'descriptor.',
            templateId: template.templateId,
          ),
        );
      } else {
        descriptorsByTemplate[template.templateId] = template;
      }

      final previousIdentity = appIdentities[template.app.appId];
      if (previousIdentity != null &&
          previousIdentity.canonicalIdentity !=
              template.app.canonicalIdentity) {
        issues.add(
          CorpusIssue(
            code: 'conflicting_app_identity',
            severity: CorpusIssueSeverity.invalid,
            message:
                'App id `${template.app.appId}` has conflicting kind, source, '
                'or revision declarations.',
            templateId: template.templateId,
          ),
        );
      } else {
        appIdentities[template.app.appId] = template.app;
      }
      for (final family in template.families) {
        familyTemplates[family]!.add(template.templateId);
      }

      final actualTemplateTasks = manifestsByTemplate[template.templateId];
      if (actualTemplateTasks == null) {
        issues.add(
          CorpusIssue(
            code: 'descriptor_unknown_template',
            severity: CorpusIssueSeverity.invalid,
            message:
                'Descriptor template `${template.templateId}` has no task '
                'manifest in the catalog.',
            templateId: template.templateId,
          ),
        );
      }

      final describedVariantIds = <String>{};
      final dimensions = <PerturbationDimension>{};
      for (final variant in template.variants) {
        final previousOwner = describedTaskIds[variant.taskId];
        if (previousOwner != null) {
          issues.add(
            CorpusIssue(
              code: 'duplicate_described_task',
              severity: CorpusIssueSeverity.invalid,
              message:
                  'Task `${variant.taskId}` is described under both '
                  '`$previousOwner` and `${template.templateId}`.',
              templateId: template.templateId,
              taskId: variant.taskId,
            ),
          );
        } else {
          describedTaskIds[variant.taskId] = template.templateId;
        }
        if (!describedVariantIds.add(variant.variantId)) {
          issues.add(
            CorpusIssue(
              code: 'duplicate_variant_id',
              severity: CorpusIssueSeverity.invalid,
              message:
                  'Variant id `${variant.variantId}` occurs more than once '
                  'under template `${template.templateId}`.',
              templateId: template.templateId,
              taskId: variant.taskId,
            ),
          );
        }
        if (!variant.semanticsPreserving) {
          issues.add(
            CorpusIssue(
              code: 'variant_not_semantics_preserving',
              severity: CorpusIssueSeverity.releaseBlocker,
              message:
                  'Variant `${variant.variantId}` is not declared '
                  'semantics-preserving.',
              templateId: template.templateId,
              taskId: variant.taskId,
            ),
          );
        }
        dimensions.addAll(variant.perturbationDimensions);

        final manifest = manifestsByTask[variant.taskId];
        if (manifest == null) {
          issues.add(
            CorpusIssue(
              code: 'descriptor_unknown_task',
              severity: CorpusIssueSeverity.invalid,
              message:
                  'Described task `${variant.taskId}` does not exist in the '
                  'catalog.',
              templateId: template.templateId,
              taskId: variant.taskId,
            ),
          );
        } else {
          if (manifest.templateId != template.templateId) {
            issues.add(
              CorpusIssue(
                code: 'described_task_template_mismatch',
                severity: CorpusIssueSeverity.invalid,
                message:
                    'Task `${variant.taskId}` belongs to template '
                    '`${manifest.templateId}`, not `${template.templateId}`.',
                templateId: template.templateId,
                taskId: variant.taskId,
              ),
            );
          }
          if (manifest.variant.variantId != variant.variantId) {
            issues.add(
              CorpusIssue(
                code: 'described_variant_id_mismatch',
                severity: CorpusIssueSeverity.invalid,
                message:
                    'Task `${variant.taskId}` declares variant '
                    '`${manifest.variant.variantId}`, not '
                    '`${variant.variantId}`.',
                templateId: template.templateId,
                taskId: variant.taskId,
              ),
            );
          }
        }
      }

      final minimumVariants =
          policy.minimumVariantsPerTemplate < goldMinimumVariantsPerTemplate
          ? goldMinimumVariantsPerTemplate
          : policy.minimumVariantsPerTemplate;
      if (template.variants.length < minimumVariants) {
        issues.add(
          CorpusIssue(
            code: 'insufficient_variants',
            severity: CorpusIssueSeverity.releaseBlocker,
            message:
                'Template `${template.templateId}` has '
                '${template.variants.length} described variants; policy '
                'requires at least $minimumVariants.',
            templateId: template.templateId,
          ),
        );
      }
      for (final required in PerturbationDimension.values) {
        if (!dimensions.contains(required)) {
          issues.add(
            CorpusIssue(
              code: 'missing_template_perturbation_dimension',
              severity: CorpusIssueSeverity.releaseBlocker,
              message:
                  'Template `${template.templateId}` does not cover required '
                  'perturbation dimension `${required.jsonName}`.',
              templateId: template.templateId,
            ),
          );
        }
      }
    }

    for (final entry in manifestsByTemplate.entries) {
      if (!descriptorsByTemplate.containsKey(entry.key)) {
        issues.add(
          CorpusIssue(
            code: 'missing_template_descriptor',
            severity: CorpusIssueSeverity.invalid,
            message:
                'Catalog template `${entry.key}` has no corpus descriptor.',
            templateId: entry.key,
          ),
        );
      }
      final variantIds = <String>{};
      final seeds = <int>{};
      for (final manifest in entry.value) {
        if (!describedTaskIds.containsKey(manifest.taskId)) {
          issues.add(
            CorpusIssue(
              code: 'missing_task_descriptor',
              severity: CorpusIssueSeverity.invalid,
              message:
                  'Catalog task `${manifest.taskId}` has no variant descriptor.',
              templateId: entry.key,
              taskId: manifest.taskId,
            ),
          );
        }
        if (!variantIds.add(manifest.variant.variantId)) {
          issues.add(
            CorpusIssue(
              code: 'catalog_duplicate_variant_id',
              severity: CorpusIssueSeverity.invalid,
              message:
                  'Template `${entry.key}` repeats variant id '
                  '`${manifest.variant.variantId}`.',
              templateId: entry.key,
              taskId: manifest.taskId,
            ),
          );
        }
        if (!seeds.add(manifest.variant.seed)) {
          issues.add(
            CorpusIssue(
              code: 'catalog_duplicate_variant_seed',
              severity: CorpusIssueSeverity.invalid,
              message:
                  'Template `${entry.key}` repeats variant seed '
                  '`${manifest.variant.seed}`.',
              templateId: entry.key,
              taskId: manifest.taskId,
            ),
          );
        }
      }
      final minimumVariants =
          policy.minimumVariantsPerTemplate < goldMinimumVariantsPerTemplate
          ? goldMinimumVariantsPerTemplate
          : policy.minimumVariantsPerTemplate;
      if (entry.value.length < minimumVariants) {
        issues.add(
          CorpusIssue(
            code: 'insufficient_manifest_variants',
            severity: CorpusIssueSeverity.releaseBlocker,
            message:
                'Template `${entry.key}` has ${entry.value.length} task '
                'manifests; policy requires at least '
                '$minimumVariants.',
            templateId: entry.key,
          ),
        );
      }
    }

    final minimumTemplates =
        policy.minimumTemplateCount < goldMinimumTemplateCount
        ? goldMinimumTemplateCount
        : policy.minimumTemplateCount;
    if (manifestsByTemplate.length < minimumTemplates) {
      issues.add(
        CorpusIssue(
          code: 'insufficient_templates',
          severity: CorpusIssueSeverity.releaseBlocker,
          message:
              'Catalog has ${manifestsByTemplate.length} templates; policy '
              'requires at least $minimumTemplates.',
        ),
      );
    }
    for (final family in CorpusTaskFamily.values) {
      final count = familyTemplates[family]!.length;
      if (count < policy.minimumTemplatesPerRequiredFamily) {
        issues.add(
          CorpusIssue(
            code: 'insufficient_required_family_breadth',
            severity: CorpusIssueSeverity.releaseBlocker,
            message:
                'Family `${family.jsonName}` has $count templates; policy '
                'requires at least '
                '${policy.minimumTemplatesPerRequiredFamily}.',
          ),
        );
      }
    }
    for (final split in BenchmarkSplit.values) {
      if (splitTemplates[split]!.isEmpty) {
        issues.add(
          CorpusIssue(
            code: 'required_split_empty',
            severity: CorpusIssueSeverity.releaseBlocker,
            message:
                'Required split `${split.jsonName}` contains no templates.',
          ),
        );
      }
    }

    final realApplications = appIdentities.values
        .where(
          (app) =>
              app.kind == CorpusAppKind.realApplication &&
              app.appId != goldStressLabAppId &&
              !policy.stressLabAppIds.contains(app.appId),
        )
        .map((app) => app.appId)
        .toSet();
    final minimumRealApps =
        policy.minimumRealAppIdentitiesBeyondStressLab <
            goldMinimumRealAppIdentitiesBeyondStressLab
        ? goldMinimumRealAppIdentitiesBeyondStressLab
        : policy.minimumRealAppIdentitiesBeyondStressLab;
    if (realApplications.length < minimumRealApps) {
      issues.add(
        CorpusIssue(
          code: 'insufficient_real_app_identities',
          severity: CorpusIssueSeverity.releaseBlocker,
          message:
              'Catalog has ${realApplications.length} distinct real-app '
              'identities beyond Stress Lab; policy requires at least '
              '$minimumRealApps.',
        ),
      );
    }

    issues.sort((first, second) {
      final severity = first.severity.index.compareTo(second.severity.index);
      if (severity != 0) return severity;
      final code = first.code.compareTo(second.code);
      if (code != 0) return code;
      final template = (first.templateId ?? '').compareTo(
        second.templateId ?? '',
      );
      if (template != 0) return template;
      return (first.taskId ?? '').compareTo(second.taskId ?? '');
    });

    final splitCounts = <String, int>{
      for (final split in BenchmarkSplit.values)
        split.jsonName: splitTemplates[split]!.length,
    };
    final familyCounts = <String, int>{
      for (final family in CorpusTaskFamily.values)
        family.jsonName: familyTemplates[family]!.length,
    };
    return CorpusValidationReport(
      issues: issues,
      taskCount: manifestsByTask.length,
      templateCount: manifestsByTemplate.length,
      descriptorTemplateCount: descriptor.templates.length,
      appIdentityCount: appIdentities.length,
      realApplicationIdentityCount: realApplications.length,
      splitTemplateCounts: splitCounts,
      familyTemplateCounts: familyCounts,
    );
  }
}

void _validateGoldPolicyFloor(CorpusPolicy policy, List<CorpusIssue> issues) {
  void below(String field, Object actual, Object minimum) {
    issues.add(
      CorpusIssue(
        code: 'policy_below_gold_floor',
        severity: CorpusIssueSeverity.invalid,
        message:
            'Policy `$field` is `$actual`; gold conformance requires '
            '`$minimum` or stronger.',
      ),
    );
  }

  if (policy.minimumTemplateCount < goldMinimumTemplateCount) {
    below(
      'minimumTemplateCount',
      policy.minimumTemplateCount,
      goldMinimumTemplateCount,
    );
  }
  if (policy.minimumVariantsPerTemplate < goldMinimumVariantsPerTemplate) {
    below(
      'minimumVariantsPerTemplate',
      policy.minimumVariantsPerTemplate,
      goldMinimumVariantsPerTemplate,
    );
  }
  if (policy.minimumRealAppIdentitiesBeyondStressLab <
      goldMinimumRealAppIdentitiesBeyondStressLab) {
    below(
      'minimumRealAppIdentitiesBeyondStressLab',
      policy.minimumRealAppIdentitiesBeyondStressLab,
      goldMinimumRealAppIdentitiesBeyondStressLab,
    );
  }
  for (final family in CorpusTaskFamily.values) {
    if (!policy.requiredFamilies.contains(family)) {
      below('requiredFamilies', 'missing ${family.jsonName}', 'all families');
    }
  }
  for (final dimension in PerturbationDimension.values) {
    if (!policy.requiredPerturbationDimensions.contains(dimension)) {
      below(
        'requiredPerturbationDimensions',
        'missing ${dimension.jsonName}',
        'all dimensions',
      );
    }
  }
  for (final split in BenchmarkSplit.values) {
    if (!policy.requiredSplits.contains(split)) {
      below('requiredSplits', 'missing ${split.jsonName}', 'all splits');
    }
  }
  if (!policy.stressLabAppIds.contains(goldStressLabAppId)) {
    below(
      'stressLabAppIds',
      'missing $goldStressLabAppId',
      'official Stress Lab identity excluded from real-app counts',
    );
  }
}

void _rejectDuplicates(Iterable<String> values, String path) {
  final seen = <String>{};
  final duplicates = <String>{};
  for (final value in values) {
    if (!seen.add(value)) duplicates.add(value);
  }
  if (duplicates.isNotEmpty) {
    final sorted = duplicates.toList()..sort();
    throw FormatException('$path contains duplicates: ${sorted.join(', ')}.');
  }
}
