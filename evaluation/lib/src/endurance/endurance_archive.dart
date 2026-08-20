import 'dart:convert';
import 'dart:io';

import '../digests.dart';
import '../json_support.dart';
import 'endurance_config.dart';
import 'endurance_contract.dart';

class EnduranceArchiveException implements Exception {
  EnduranceArchiveException(this.message);

  final String message;

  @override
  String toString() => 'Endurance archive error: $message';
}

class EnduranceArchiveWriter {
  EnduranceArchiveWriter._({
    required this.directory,
    required this.maximumBytes,
    required List<EnduranceArchiveEntry> inventory,
    required int bytesWritten,
  }) : _inventory = inventory,
       _bytesWritten = bytesWritten;

  final Directory directory;
  final int maximumBytes;
  final List<EnduranceArchiveEntry> _inventory;
  int _bytesWritten;
  bool _finalized = false;

  List<EnduranceArchiveEntry> get inventory =>
      List<EnduranceArchiveEntry>.unmodifiable(_inventory);

  static Future<EnduranceArchiveWriter> create({
    required Directory parent,
    required EnduranceConfig config,
    required DateTime createdAtUtc,
  }) async {
    if (!createdAtUtc.isUtc) {
      throw ArgumentError.value(createdAtUtc, 'createdAtUtc', 'must be UTC');
    }
    await _ensurePrivateDirectory(parent);
    final claim = File('${parent.path}/${config.enduranceRunId}.claim');
    try {
      await claim.create(exclusive: true);
      if (!Platform.isWindows) await _setMode('600', claim.path);
    } on FileSystemException {
      if (await claim.exists()) {
        throw EnduranceArchiveException(
          'Run `${config.enduranceRunId}` already has an archive claim; '
          'evidence is create-only.',
        );
      }
      rethrow;
    }
    final directory = Directory('${parent.path}/${config.enduranceRunId}');
    try {
      final existingType = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (existingType != FileSystemEntityType.notFound) {
        throw EnduranceArchiveException(
          'Archive `${directory.path}` already exists and will not be '
          'overwritten.',
        );
      }
      await directory.create();
      if (!Platform.isWindows) {
        await _setMode('700', directory.path);
      }
      final writer = EnduranceArchiveWriter._(
        directory: directory,
        maximumBytes: config.limits.maximumArchiveBytes,
        inventory: <EnduranceArchiveEntry>[],
        bytesWritten: 0,
      );
      await writer._write('manifest.json', <String, Object?>{
        'schemaVersion': enduranceArchiveSchemaVersion,
        'recordType': 'manifest',
        'createdAtUtc': createdAtUtc.toIso8601String(),
        'configSha256': config.sha256,
        'environmentSha256': config.environment.sha256,
        'planSha256': config.plan.sha256,
        'config': config.toJson(),
      });
      return writer;
    } on Object {
      // The claim intentionally remains as a fail-safe tombstone. A partially
      // created archive is evidence and must never be silently reused.
      rethrow;
    }
  }

  Future<EnduranceArchiveEntry> preserveEvent(
    String name,
    Map<String, Object?> event,
  ) {
    if (!RegExp(r'^[a-z][a-z0-9_-]*$').hasMatch(name)) {
      throw ArgumentError.value(name, 'name');
    }
    return _write('$name.json', event);
  }

  Future<EnduranceArchiveEntry> preserveStep(EnduranceStepRecord step) =>
      _write(
        'steps/${step.sequence.toString().padLeft(6, '0')}.json',
        step.toJson(),
      );

  Future<EnduranceRunResult> finalize(EnduranceOutcome outcome) async {
    if (_finalized) {
      throw StateError('The endurance archive has already been finalized.');
    }
    _finalized = true;
    final expectedInventory = inventory;
    if (canonicalJsonEncode(<Map<String, Object?>>[
          for (final item in outcome.inventory) item.toJson(),
        ]) !=
        canonicalJsonEncode(<Map<String, Object?>>[
          for (final item in expectedInventory) item.toJson(),
        ])) {
      throw EnduranceArchiveException(
        'Outcome inventory does not exactly match preserved evidence.',
      );
    }
    final outcomeEntry = await _write('outcome.json', outcome.toJson());
    final archiveSha256 = jsonSha256(<Map<String, Object?>>[
      for (final item in <EnduranceArchiveEntry>[
        ...expectedInventory,
        outcomeEntry,
      ])
        item.toJson(),
    ]);
    return EnduranceRunResult(
      outcome: outcome,
      archiveDirectory: directory.path,
      archiveSha256: archiveSha256,
    );
  }

  Future<EnduranceArchiveEntry> _write(
    String relativePath,
    Map<String, Object?> value,
  ) async {
    if (_finalized && relativePath != 'outcome.json') {
      throw StateError('The endurance archive has already been finalized.');
    }
    final bytes = utf8.encode('${canonicalJsonEncode(value)}\n');
    if (_bytesWritten + bytes.length > maximumBytes) {
      throw EnduranceArchiveException(
        'Writing `$relativePath` would exceed the preregistered '
        '$maximumBytes-byte archive bound.',
      );
    }
    final file = File('${directory.path}/$relativePath');
    final parent = file.parent;
    final parentType = await FileSystemEntity.type(
      parent.path,
      followLinks: false,
    );
    if (parentType == FileSystemEntityType.notFound) {
      await parent.create();
      if (!Platform.isWindows) {
        await _setMode('700', parent.path);
      }
    } else if (parentType != FileSystemEntityType.directory) {
      throw EnduranceArchiveException(
        'Archive parent `${parent.path}` is not a real directory.',
      );
    }
    try {
      await file.create(exclusive: true);
    } on FileSystemException {
      if (await file.exists()) {
        throw EnduranceArchiveException(
          'Evidence `$relativePath` already exists and will not be '
          'overwritten.',
        );
      }
      rethrow;
    }
    final handle = await file.open(mode: FileMode.writeOnly);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
    if (!Platform.isWindows) {
      await _setMode('600', file.path);
    }
    final entry = EnduranceArchiveEntry(
      relativePath: relativePath,
      sha256: sha256Bytes(bytes),
      byteLength: bytes.length,
    );
    _inventory.add(entry);
    _bytesWritten += bytes.length;
    return entry;
  }
}

class LoadedEnduranceArchive {
  const LoadedEnduranceArchive({
    required this.outcome,
    required this.archiveSha256,
  });

  final EnduranceOutcome outcome;
  final String archiveSha256;
}

class ImmutableEnduranceArchiveLoader {
  const ImmutableEnduranceArchiveLoader();

  Future<LoadedEnduranceArchive> load(Directory directory) async {
    final directoryType = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (directoryType != FileSystemEntityType.directory) {
      throw EnduranceArchiveException(
        '`${directory.path}` is not a real endurance archive directory.',
      );
    }
    if (!Platform.isWindows) {
      final mode = (await directory.stat()).mode & 0x1ff;
      if ((mode & 0x3f) != 0) {
        throw EnduranceArchiveException(
          'Endurance archive directory is not owner-only.',
        );
      }
    }
    final outcomeFile = File('${directory.path}/outcome.json');
    final outcomeBytes = await _readStableRegularFile(outcomeFile);
    final outcome = EnduranceOutcome.fromJson(
      jsonDecode(utf8.decode(outcomeBytes, allowMalformed: false)),
    );
    final actualEntries = <EnduranceArchiveEntry>[];
    final bytesByPath = <String, List<int>>{};
    final expectedPaths = <String>{};
    for (final expected in outcome.inventory) {
      if (!expectedPaths.add(expected.relativePath)) {
        throw EnduranceArchiveException(
          'Duplicate inventory entry `${expected.relativePath}`.',
        );
      }
      final bytes = await _readStableRegularFile(
        File('${directory.path}/${expected.relativePath}'),
      );
      final actual = EnduranceArchiveEntry(
        relativePath: expected.relativePath,
        sha256: sha256Bytes(bytes),
        byteLength: bytes.length,
      );
      if (actual.sha256 != expected.sha256 ||
          actual.byteLength != expected.byteLength) {
        throw EnduranceArchiveException(
          'Evidence `${expected.relativePath}` no longer matches its exact '
          'byte inventory.',
        );
      }
      actualEntries.add(actual);
      bytesByPath[expected.relativePath] = bytes;
    }
    final allowedPaths = <String>{...expectedPaths, 'outcome.json'};
    final entities = await directory
        .list(recursive: true, followLinks: false)
        .toList();
    for (final entity in entities) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.directory) continue;
      if (type != FileSystemEntityType.file) {
        throw EnduranceArchiveException(
          'Archive contains a non-regular entry `${entity.path}`.',
        );
      }
      final relative = entity.path.substring(directory.path.length + 1);
      if (!allowedPaths.contains(relative)) {
        throw EnduranceArchiveException(
          'Archive contains unindexed evidence `$relative`.',
        );
      }
    }
    final outcomeEntry = EnduranceArchiveEntry(
      relativePath: 'outcome.json',
      sha256: sha256Bytes(outcomeBytes),
      byteLength: outcomeBytes.length,
    );
    _validateArchiveContents(outcome, bytesByPath);
    return LoadedEnduranceArchive(
      outcome: outcome,
      archiveSha256: jsonSha256(<Map<String, Object?>>[
        for (final item in <EnduranceArchiveEntry>[
          ...actualEntries,
          outcomeEntry,
        ])
          item.toJson(),
      ]),
    );
  }
}

void _validateArchiveContents(
  EnduranceOutcome outcome,
  Map<String, List<int>> bytesByPath,
) {
  final manifestBytes = bytesByPath['manifest.json'];
  if (manifestBytes == null) {
    throw EnduranceArchiveException(
      'Archive inventory is missing manifest.json.',
    );
  }
  final manifest = expectJsonObject(
    jsonDecode(utf8.decode(manifestBytes, allowMalformed: false)),
    r'$.manifest',
  );
  if (manifest['recordType'] != 'manifest' || manifest['schemaVersion'] != 1) {
    throw EnduranceArchiveException(
      'Archive manifest has the wrong type/version.',
    );
  }
  final config = EnduranceConfig.fromJson(manifest['config']);
  if (config.enduranceRunId != outcome.enduranceRunId ||
      config.sha256 != outcome.configSha256 ||
      config.environment.sha256 != outcome.environmentSha256 ||
      config.plan.sha256 != outcome.planSha256 ||
      manifest['configSha256'] != outcome.configSha256 ||
      manifest['environmentSha256'] != outcome.environmentSha256 ||
      manifest['planSha256'] != outcome.planSha256) {
    throw EnduranceArchiveException(
      'Manifest/config pins do not match the finalized outcome.',
    );
  }
  if (outcome.freshSetupProven && !bytesByPath.containsKey('setup.json')) {
    throw EnduranceArchiveException(
      'Fresh setup is claimed without setup evidence.',
    );
  }
  if (outcome.cleanTeardownProven &&
      !bytesByPath.containsKey('teardown.json')) {
    throw EnduranceArchiveException(
      'Clean teardown is claimed without teardown evidence.',
    );
  }
  final stepPaths =
      bytesByPath.keys
          .where((path) => path.startsWith('steps/') && path.endsWith('.json'))
          .toList()
        ..sort();
  if (stepPaths.length != outcome.actionCount) {
    throw EnduranceArchiveException(
      'Outcome actionCount does not match the exact step inventory.',
    );
  }
  String? previous;
  for (var index = 0; index < stepPaths.length; index++) {
    final expectedPath = 'steps/${(index + 1).toString().padLeft(6, '0')}.json';
    if (stepPaths[index] != expectedPath) {
      throw EnduranceArchiveException(
        'Step archive has a missing, extra, or out-of-order sequence.',
      );
    }
    final bytes = bytesByPath[expectedPath]!;
    final step = expectJsonObject(
      jsonDecode(utf8.decode(bytes, allowMalformed: false)),
      r'$.step',
    );
    if (step['recordType'] != 'step' ||
        step['schemaVersion'] != 1 ||
        step['sequence'] != index + 1 ||
        step['previousRecordSha256'] != previous) {
      throw EnduranceArchiveException(
        'Step $expectedPath breaks the typed hash chain.',
      );
    }
    previous = sha256Bytes(bytes);
  }
  if (outcome.finalRecordSha256 != previous) {
    throw EnduranceArchiveException(
      'Outcome finalRecordSha256 does not close the exact step chain.',
    );
  }
}

Future<void> _ensurePrivateDirectory(Directory directory) async {
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    await directory.create(recursive: true);
    if (!Platform.isWindows) {
      await _setMode('700', directory.path);
    }
    return;
  }
  if (type != FileSystemEntityType.directory) {
    throw EnduranceArchiveException(
      'Archive parent `${directory.path}` must be a real directory.',
    );
  }
  if (!Platform.isWindows) {
    final mode = (await directory.stat()).mode & 0x1ff;
    if ((mode & 0x3f) != 0) {
      throw EnduranceArchiveException(
        'Existing archive parent `${directory.path}` must be owner-only; '
        'found mode ${mode.toRadixString(8).padLeft(3, '0')}.',
      );
    }
  }
}

Future<void> _setMode(String mode, String path) async {
  final result = await Process.run('chmod', <String>[mode, path]);
  if (result.exitCode != 0) {
    throw EnduranceArchiveException(
      'Could not apply private mode $mode to `$path`.',
    );
  }
}

Future<List<int>> _readStableRegularFile(File file) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw EnduranceArchiveException(
      'Expected a regular archive file at `${file.path}`.',
    );
  }
  final before = await file.stat();
  if (!Platform.isWindows && ((before.mode & 0x1ff) & 0x3f) != 0) {
    throw EnduranceArchiveException(
      'Archive file `${file.path}` is not owner-only.',
    );
  }
  final bytes = await file.readAsBytes();
  final after = await file.stat();
  if (before.type != FileSystemEntityType.file ||
      after.type != FileSystemEntityType.file ||
      before.size != after.size ||
      before.modified != after.modified ||
      before.changed != after.changed ||
      before.size != bytes.length) {
    throw EnduranceArchiveException(
      'Archive file `${file.path}` changed while it was read.',
    );
  }
  return bytes;
}
