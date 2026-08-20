import 'dart:convert';
import 'dart:io';

import 'input_io.dart';
import 'task_manifest.dart';

class CatalogSets {
  const CatalogSets({
    required this.publicDevelopment,
    required this.privateValidation,
    required this.frozenHiddenRelease,
  });

  final List<TaskManifest> publicDevelopment;
  final List<TaskManifest> privateValidation;
  final List<TaskManifest> frozenHiddenRelease;

  Iterable<({BenchmarkSplit bucket, TaskManifest manifest})> get entries sync* {
    for (final manifest in publicDevelopment) {
      yield (bucket: BenchmarkSplit.publicDevelopment, manifest: manifest);
    }
    for (final manifest in privateValidation) {
      yield (bucket: BenchmarkSplit.privateValidation, manifest: manifest);
    }
    for (final manifest in frozenHiddenRelease) {
      yield (bucket: BenchmarkSplit.frozenHiddenRelease, manifest: manifest);
    }
  }
}

class CatalogIssue {
  const CatalogIssue({
    required this.code,
    required this.message,
    this.taskId,
    this.templateId,
  });

  final String code;
  final String message;
  final String? taskId;
  final String? templateId;

  Map<String, Object?> toJson() => {
    'code': code,
    'message': message,
    if (taskId != null) 'taskId': taskId,
    if (templateId != null) 'templateId': templateId,
  };
}

class CatalogValidationReport {
  CatalogValidationReport({
    required Iterable<CatalogIssue> issues,
    required this.taskCount,
    required this.templateCount,
  }) : issues = List<CatalogIssue>.unmodifiable(issues);

  final List<CatalogIssue> issues;
  final int taskCount;
  final int templateCount;

  bool get isValid => issues.isEmpty;

  Map<String, Object?> toJson() => {
    'ok': isValid,
    'taskCount': taskCount,
    'templateCount': templateCount,
    'issues': [for (final issue in issues) issue.toJson()],
  };

  void throwIfInvalid() {
    if (!isValid) throw CatalogValidationException(this);
  }
}

class CatalogValidationException implements Exception {
  const CatalogValidationException(this.report);

  final CatalogValidationReport report;

  @override
  String toString() =>
      'Catalog validation failed with ${report.issues.length} issue(s).';
}

class CatalogValidator {
  const CatalogValidator();

  CatalogValidationReport validate(CatalogSets sets) {
    final issues = <CatalogIssue>[];
    final taskIds = <String, TaskManifest>{};
    final templateSplits = <String, BenchmarkSplit>{};
    var taskCount = 0;

    for (final entry in sets.entries) {
      taskCount++;
      final manifest = entry.manifest;
      if (manifest.split != entry.bucket) {
        issues.add(
          CatalogIssue(
            code: 'manifest_bucket_mismatch',
            message:
                'Task `${manifest.taskId}` declares `${manifest.split.jsonName}` '
                'but was loaded from `${entry.bucket.jsonName}`.',
            taskId: manifest.taskId,
            templateId: manifest.templateId,
          ),
        );
      }

      final previousTask = taskIds[manifest.taskId];
      if (previousTask != null) {
        issues.add(
          CatalogIssue(
            code: 'duplicate_task_id',
            message:
                'Task id `${manifest.taskId}` is used by variants '
                '`${previousTask.variant.variantId}` and '
                '`${manifest.variant.variantId}`.',
            taskId: manifest.taskId,
            templateId: manifest.templateId,
          ),
        );
      } else {
        taskIds[manifest.taskId] = manifest;
      }

      final previousSplit = templateSplits[manifest.templateId];
      if (previousSplit != null && previousSplit != entry.bucket) {
        issues.add(
          CatalogIssue(
            code: 'template_split_overlap',
            message:
                'Template `${manifest.templateId}` appears in both '
                '`${previousSplit.jsonName}` and `${entry.bucket.jsonName}`. '
                'Splits are disjoint by template id, not seed or variant.',
            taskId: manifest.taskId,
            templateId: manifest.templateId,
          ),
        );
      } else {
        templateSplits[manifest.templateId] = entry.bucket;
      }
    }

    issues.sort((first, second) {
      final code = first.code.compareTo(second.code);
      if (code != 0) return code;
      final template = (first.templateId ?? '').compareTo(
        second.templateId ?? '',
      );
      if (template != 0) return template;
      return (first.taskId ?? '').compareTo(second.taskId ?? '');
    });
    return CatalogValidationReport(
      issues: issues,
      taskCount: taskCount,
      templateCount: templateSplits.length,
    );
  }
}

class CatalogLoader {
  const CatalogLoader({
    this.maximumManifestFiles = 10000,
    this.maximumManifestBytes = 1024 * 1024,
    this.maximumCatalogBytes = 64 * 1024 * 1024,
    this.maximumEntries = 20000,
  }) : assert(maximumManifestFiles > 0),
       assert(maximumManifestBytes > 0),
       assert(maximumCatalogBytes >= maximumManifestBytes),
       assert(maximumEntries >= maximumManifestFiles);

  final int maximumManifestFiles;
  final int maximumManifestBytes;
  final int maximumCatalogBytes;
  final int maximumEntries;

  Future<CatalogSets> load(Directory root) async {
    var fileCount = 0;
    var totalBytes = 0;
    var entryCount = 0;
    Future<List<TaskManifest>> split(String directoryName) async {
      final directory = Directory('${root.path}/$directoryName');
      final directoryType = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (directoryType == FileSystemEntityType.notFound) return const [];
      if (directoryType != FileSystemEntityType.directory) {
        throw FormatException(
          'Catalog split `${directory.path}` must be a real directory.',
        );
      }
      final files = <File>[];
      await for (final entry in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        entryCount += 1;
        if (entryCount > maximumEntries) {
          throw FormatException(
            'Catalog exceeds the $maximumEntries-entry traversal bound.',
          );
        }
        final type = await FileSystemEntity.type(
          entry.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) continue;
        if (type != FileSystemEntityType.file ||
            !entry.path.endsWith('.json')) {
          throw FormatException(
            'Catalog entries must be regular `.json` files; found '
            '`${entry.path}`.',
          );
        }
        fileCount += 1;
        if (fileCount > maximumManifestFiles) {
          throw FormatException(
            'Catalog exceeds the $maximumManifestFiles-manifest bound.',
          );
        }
        files.add(File(entry.path));
      }
      files.sort((first, second) => first.path.compareTo(second.path));
      final manifests = <TaskManifest>[];
      for (final file in files) {
        final bytes = await readStableBoundedRegularFile(
          file,
          maximumBytes: maximumManifestBytes,
        );
        totalBytes += bytes.length;
        if (totalBytes > maximumCatalogBytes) {
          throw FormatException(
            'Catalog exceeds the $maximumCatalogBytes-byte aggregate bound.',
          );
        }
        manifests.add(
          TaskManifest.fromJson(
            jsonDecode(utf8.decode(bytes, allowMalformed: false)),
          ),
        );
      }
      return List<TaskManifest>.unmodifiable(manifests);
    }

    return CatalogSets(
      publicDevelopment: await split('public'),
      privateValidation: await split('private'),
      frozenHiddenRelease: await split('frozen'),
    );
  }
}
