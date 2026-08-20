import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

void main() {
  late CorpusPolicy policy;

  setUpAll(() {
    policy = CorpusPolicy.fromJson(
      jsonDecode(File('policies/gold_conformance.v1.json').readAsStringSync()),
    );
  });

  test('gold policy pins every QUALITY_STANDARD corpus minimum and axis', () {
    expect(policy.minimumTemplateCount, 60);
    expect(policy.minimumVariantsPerTemplate, 5);
    expect(policy.minimumRealAppIdentitiesBeyondStressLab, 2);
    expect(policy.requiredFamilies.toSet(), CorpusTaskFamily.values.toSet());
    expect(
      policy.requiredPerturbationDimensions.toSet(),
      PerturbationDimension.values.toSet(),
    );
    expect(policy.requiredSplits.toSet(), BenchmarkSplit.values.toSet());
  });

  test('runnable public generator is deterministic and covers 60 by 5', () {
    const generator = PublicAuthoringCatalogGenerator();
    final first = generator.generate();
    final second = generator.generate();

    expect(first.descriptor.templates, hasLength(60));
    expect(first.catalog.publicDevelopment, hasLength(300));
    expect(first.catalog.privateValidation, isEmpty);
    expect(first.catalog.frozenHiddenRelease, isEmpty);
    expect(
      canonicalJsonEncode(first.descriptor.toJson()),
      canonicalJsonEncode(second.descriptor.toJson()),
    );
    expect(
      computeCatalogSha256(first.catalog),
      computeCatalogSha256(second.catalog),
    );

    final report = const CorpusValidator().validate(
      catalog: first.catalog,
      descriptor: first.descriptor,
      policy: policy,
    );
    expect(report.isValid, isTrue);
    expect(report.releaseEligible, isFalse);
    expect(report.issues.map((issue) => issue.code).toSet(), {
      'required_split_empty',
      'insufficient_real_app_identities',
    });
    expect(
      report.familyTemplateCounts.values.every((count) => count == 5),
      isTrue,
    );
  });

  test('complete catalog can become release eligible only with all splits and '
      'two explicit real apps', () {
    final generated = const PublicAuthoringCatalogGenerator().generate();
    final public = <TaskManifest>[];
    final private = <TaskManifest>[];
    final frozen = <TaskManifest>[];
    final templates = <CorpusTemplateDescriptor>[];

    for (
      var index = 0;
      index < generated.descriptor.templates.length;
      index++
    ) {
      final originalDescriptor = generated.descriptor.templates[index];
      final split = index < 20
          ? BenchmarkSplit.publicDevelopment
          : index < 40
          ? BenchmarkSplit.privateValidation
          : BenchmarkSplit.frozenHiddenRelease;
      final app = index < 20
          ? originalDescriptor.app
          : index < 40
          ? CorpusAppIdentity(
              appId: 'real-app-one',
              displayName: 'Real app one',
              kind: CorpusAppKind.realApplication,
              source: 'https://example.invalid/real-app-one',
              revision: 'a' * 40,
            )
          : CorpusAppIdentity(
              appId: 'real-app-two',
              displayName: 'Real app two',
              kind: CorpusAppKind.realApplication,
              source: 'https://example.invalid/real-app-two',
              revision: 'b' * 40,
            );
      templates.add(
        CorpusTemplateDescriptor(
          templateId: originalDescriptor.templateId,
          app: app,
          families: originalDescriptor.families,
          variants: originalDescriptor.variants,
        ),
      );
      final templateTasks = generated.catalog.publicDevelopment.where(
        (task) => task.templateId == originalDescriptor.templateId,
      );
      for (final task in templateTasks) {
        final json = task.toJson()..['split'] = split.jsonName;
        final moved = TaskManifest.fromJson(json);
        switch (split) {
          case BenchmarkSplit.publicDevelopment:
            public.add(moved);
          case BenchmarkSplit.privateValidation:
            private.add(moved);
          case BenchmarkSplit.frozenHiddenRelease:
            frozen.add(moved);
        }
      }
    }

    final report = const CorpusValidator().validate(
      catalog: CatalogSets(
        publicDevelopment: public,
        privateValidation: private,
        frozenHiddenRelease: frozen,
      ),
      descriptor: CorpusDescriptor(
        corpusId: 'complete-test-corpus',
        corpusVersion: '1',
        templates: templates,
      ),
      policy: policy,
    );

    expect(report.isValid, isTrue, reason: jsonEncode(report.toJson()));
    expect(report.releaseEligible, isTrue, reason: jsonEncode(report.toJson()));
    expect(report.realApplicationIdentityCount, 2);
    expect(report.issues, isEmpty);
  });

  test('a custom policy can strengthen but cannot weaken gold floors', () {
    final weakJson = policy.toJson()
      ..['minimumTemplateCount'] = 1
      ..['minimumVariantsPerTemplate'] = 1
      ..['minimumRealAppIdentitiesBeyondStressLab'] = 1
      ..['requiredFamilies'] = ['forms']
      ..['requiredPerturbationDimensions'] = ['viewport']
      ..['requiredSplits'] = ['public_development']
      ..['stressLabAppIds'] = ['lookalike-stress-lab'];
    final weakPolicy = CorpusPolicy.fromJson(weakJson);
    final generated = const PublicAuthoringCatalogGenerator().generate();

    final report = const CorpusValidator().validate(
      catalog: generated.catalog,
      descriptor: generated.descriptor,
      policy: weakPolicy,
    );

    expect(report.isValid, isFalse);
    expect(report.releaseEligible, isFalse);
    expect(
      report.issues
          .where((issue) => issue.code == 'policy_below_gold_floor')
          .length,
      greaterThanOrEqualTo(6),
    );
  });

  test('descriptor mismatch is invalid while breadth gaps are blockers', () {
    final generated = const PublicAuthoringCatalogGenerator().generate();
    final first = generated.descriptor.templates.first;
    final damaged = CorpusTemplateDescriptor(
      templateId: first.templateId,
      app: first.app,
      families: first.families,
      variants: [
        CorpusVariantDescriptor(
          taskId: first.variants.first.taskId,
          variantId: 'wrong-variant',
          semanticsPreserving: false,
          perturbationDimensions: const [PerturbationDimension.viewport],
        ),
      ],
    );
    final descriptor = CorpusDescriptor(
      corpusId: generated.descriptor.corpusId,
      corpusVersion: generated.descriptor.corpusVersion,
      templates: [damaged, ...generated.descriptor.templates.skip(1)],
    );

    final report = const CorpusValidator().validate(
      catalog: generated.catalog,
      descriptor: descriptor,
      policy: policy,
    );
    final codes = report.issues.map((issue) => issue.code).toSet();
    expect(report.isValid, isFalse);
    expect(report.releaseEligible, isFalse);
    expect(codes, contains('described_variant_id_mismatch'));
    expect(codes, contains('missing_task_descriptor'));
    expect(codes, contains('insufficient_variants'));
    expect(codes, contains('missing_template_perturbation_dimension'));
    expect(codes, contains('variant_not_semantics_preserving'));
  });

  test('agent projection cannot contain corpus or hidden harness metadata', () {
    final generated = const PublicAuthoringCatalogGenerator().generate();
    final manifest = generated.catalog.publicDevelopment.first;
    final projected = manifest.toAgentView().toJson();
    final keys = _jsonKeys(projected);

    expect(projected.keys.toSet(), {
      'schemaVersion',
      'taskId',
      'instruction',
      'allowedTools',
      'budget',
    });
    for (final forbidden in const [
      'templateId',
      'split',
      'variant',
      'hiddenHarness',
      'oracle',
      'successPredicate',
      'forbiddenPredicate',
      'appId',
      'families',
      'perturbationDimensions',
      'semanticsPreserving',
    ]) {
      expect(keys, isNot(contains(forbidden)));
    }
  });

  test('catalog CLI validates public fixtures but rejects release', () async {
    final root = await Directory.systemTemp.createTemp('scout-corpus-cli-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final catalog = Directory('${root.path}/catalog');
    final generated = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/generate_public_catalog.dart',
      catalog.path,
    ]);
    expect(generated.exitCode, 0, reason: '${generated.stderr}');
    final generatedJson =
        jsonDecode(generated.stdout as String) as Map<String, Object?>;
    expect(generatedJson['publicFixturesRunnable'], isTrue);
    expect(generatedJson['fixtureRevision'], publicFixtureRevision);

    final authoring = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/validate_catalog.dart',
      catalog.path,
    ]);
    expect(authoring.exitCode, 0, reason: '${authoring.stderr}');
    final authoringJson =
        jsonDecode(authoring.stdout as String) as Map<String, Object?>;
    expect(authoringJson['ok'], isTrue);
    expect(authoringJson['releaseEligible'], isFalse);

    final release = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/validate_catalog.dart',
      '--catalog',
      catalog.path,
      '--require-release-eligible',
    ]);
    expect(release.exitCode, 2, reason: '${release.stderr}');
    final releaseJson =
        jsonDecode(release.stdout as String) as Map<String, Object?>;
    expect(releaseJson['releaseEligible'], isFalse);
    final corpusJson = releaseJson['corpus']! as Map<String, Object?>;
    expect(corpusJson['templateCount'], 60);
    expect(corpusJson['taskCount'], 300);
  });
}

Set<String> _jsonKeys(Object? value) {
  final result = <String>{};
  void visit(Object? current) {
    if (current is Map<Object?, Object?>) {
      for (final entry in current.entries) {
        if (entry.key is String) result.add(entry.key as String);
        visit(entry.value);
      }
    } else if (current is List<Object?>) {
      for (final item in current) {
        visit(item);
      }
    }
  }

  visit(value);
  return result;
}
