import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  const validator = CatalogValidator();

  test('variants of one template may coexist only inside one split', () {
    final report = validator.validate(
      CatalogSets(
        publicDevelopment: [
          testManifest(),
          testManifest(
            taskId: 'save-profile.variant-b',
            variantId: 'variant-b',
            seed: 8,
          ),
        ],
        privateValidation: const [],
        frozenHiddenRelease: const [],
      ),
    );

    expect(report.isValid, isTrue);
    expect(report.taskCount, 2);
    expect(report.templateCount, 1);
  });

  test('same template id across public and private splits is rejected', () {
    final report = validator.validate(
      CatalogSets(
        publicDevelopment: [testManifest()],
        privateValidation: [
          testManifest(
            taskId: 'save-profile.private-a',
            split: BenchmarkSplit.privateValidation,
            variantId: 'private-a',
          ),
        ],
        frozenHiddenRelease: const [],
      ),
    );

    expect(report.isValid, isFalse);
    expect(
      report.issues.map((issue) => issue.code),
      contains('template_split_overlap'),
    );
    expect(
      () => report.throwIfInvalid(),
      throwsA(isA<CatalogValidationException>()),
    );
  });

  test('manifest declared split must match its catalog bucket', () {
    final report = validator.validate(
      CatalogSets(
        publicDevelopment: const [],
        privateValidation: [testManifest()],
        frozenHiddenRelease: const [],
      ),
    );

    expect(
      report.issues.map((issue) => issue.code),
      contains('manifest_bucket_mismatch'),
    );
  });

  test('task ids are globally unique even when templates differ', () {
    final report = validator.validate(
      CatalogSets(
        publicDevelopment: [
          testManifest(),
          testManifest(templateId: 'another-template'),
        ],
        privateValidation: const [],
        frozenHiddenRelease: const [],
      ),
    );

    expect(
      report.issues.map((issue) => issue.code),
      contains('duplicate_task_id'),
    );
  });

  test(
    'catalog loader rejects oversized and non-regular manifest entries',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'scout-catalog-input-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final split = Directory('${root.path}/public')..createSync();
      final manifest = File('${split.path}/task.json')
        ..writeAsStringSync(jsonEncode(testManifest().toJson()));

      await expectLater(
        const CatalogLoader(
          maximumManifestBytes: 32,
          maximumCatalogBytes: 32,
        ).load(root),
        throwsA(isA<EvaluationInputException>()),
      );

      if (!Platform.isWindows) {
        manifest.deleteSync();
        final victim = File('${root.path}/victim.json')
          ..writeAsStringSync(jsonEncode(testManifest().toJson()));
        await Link(manifest.path).create(victim.path);
        await expectLater(
          const CatalogLoader().load(root),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );
}
