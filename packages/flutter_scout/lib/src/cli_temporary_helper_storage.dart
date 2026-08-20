part of 'flutter_scout_cli.dart';

extension _CliTemporaryHelperPaths on FlutterScoutCli {
  Future<_TemporaryHelperPaths> _temporaryHelperValidatedPaths({
    required String project,
    required String originalTarget,
    required String? helperPath,
    required String runId,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(runId)) {
      throw const ScoutCliException(
        'temporary_helper_run_id_invalid',
        'The temporary-helper run identity is invalid or too long.',
      );
    }
    final projectPath = _temporaryHelperCanonicalProject(project);
    final pubspecPath = p.join(projectPath, 'pubspec.yaml');
    _temporaryHelperRequireRegularFile(
      pubspecPath,
      code: 'temporary_helper_pubspec_missing',
      message: 'Temporary helper setup requires a regular pubspec.yaml.',
    );
    final requestedTarget = p.isAbsolute(originalTarget)
        ? _absoluteNormalized(originalTarget)
        : _absoluteNormalized(p.join(projectPath, originalTarget));
    _temporaryHelperRequireRegularFile(
      requestedTarget,
      code: 'temporary_helper_target_missing',
      message: 'The original Flutter target does not exist or is not regular.',
    );
    final originalTargetPath = File(requestedTarget).resolveSymbolicLinksSync();
    if (!p.isWithin(projectPath, originalTargetPath)) {
      throw const ScoutCliException(
        'temporary_helper_target_outside_project',
        'The original Flutter target must resolve inside the exact project.',
      );
    }
    final discoveredHelper = helperPath ?? await _discoverBundledHelperPath();
    if (discoveredHelper == null || discoveredHelper.isEmpty) {
      throw const ScoutCliException(
        'temporary_helper_path_missing',
        'Could not locate flutter_scout_helper. Pass '
            '`--helper-path <path-to-flutter_scout_helper>`.',
      );
    }
    final helperDirectory = Directory(_absoluteNormalized(discoveredHelper));
    if (!helperDirectory.existsSync()) {
      throw const ScoutCliException(
        'temporary_helper_path_missing',
        'The flutter_scout_helper directory does not exist.',
      );
    }
    final resolvedHelper = helperDirectory.resolveSymbolicLinksSync();
    _temporaryHelperRequireRegularFile(
      p.join(resolvedHelper, 'pubspec.yaml'),
      code: 'temporary_helper_path_missing',
      message: 'The helper path has no regular pubspec.yaml.',
    );
    final scoutRoot = p.join(projectPath, '.flutter_scout');
    final scoutType = FileSystemEntity.typeSync(scoutRoot, followLinks: false);
    if (scoutType != FileSystemEntityType.notFound &&
        scoutType != FileSystemEntityType.directory) {
      throw const ScoutCliException(
        'temporary_helper_scout_root_unsafe',
        'The project .flutter_scout path must be a real directory, never a '
            'symbolic link or special filesystem object.',
      );
    }
    // Boundary equals the managed directory itself: this secures Scout's
    // private subtree without chmodding the project or another legitimate
    // parent directory.
    _ensurePrivateDirectory(scoutRoot, boundary: scoutRoot);
    final transactionId = runId;
    final transactionDir = p.join(
      scoutRoot,
      'temporary_helper',
      'transactions',
      transactionId,
    );
    if (FileSystemEntity.typeSync(transactionDir, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const ScoutCliException(
        'temporary_helper_transaction_exists',
        'A transaction with this exact run identity already exists. Run '
            '`flutter-scout doctor` to repair it before retrying.',
      );
    }
    final paths = _TemporaryHelperPaths(
      projectPath: projectPath,
      scoutRoot: scoutRoot,
      transactionId: transactionId,
      transactionDir: transactionDir,
      recordPath: p.join(transactionDir, 'repair.json'),
      helperPath: resolvedHelper,
      originalTargetPath: originalTargetPath,
      generatedTargetPath: p.join(scoutRoot, 'bootstrap_$runId.dart'),
      pubspecPath: pubspecPath,
      pubspecBackupPath: p.join(transactionDir, 'pubspec.yaml.original'),
      lockPath: p.join(projectPath, 'pubspec.lock'),
      lockBackupPath: p.join(transactionDir, 'pubspec.lock.original'),
    );
    for (final value in paths.allPaths) {
      if (!_temporaryHelperValidAbsolutePath(value)) {
        throw const ScoutCliException(
          'temporary_helper_path_invalid',
          'A temporary-helper path is not an absolute bounded path.',
        );
      }
    }
    return paths;
  }
}

final class _TemporaryHelperPaths {
  const _TemporaryHelperPaths({
    required this.projectPath,
    required this.scoutRoot,
    required this.transactionId,
    required this.transactionDir,
    required this.recordPath,
    required this.helperPath,
    required this.originalTargetPath,
    required this.generatedTargetPath,
    required this.pubspecPath,
    required this.pubspecBackupPath,
    required this.lockPath,
    required this.lockBackupPath,
  });

  final String projectPath;
  final String scoutRoot;
  final String transactionId;
  final String transactionDir;
  final String recordPath;
  final String helperPath;
  final String originalTargetPath;
  final String generatedTargetPath;
  final String pubspecPath;
  final String pubspecBackupPath;
  final String lockPath;
  final String lockBackupPath;

  List<String> get allPaths => <String>[
    projectPath,
    scoutRoot,
    transactionDir,
    recordPath,
    helperPath,
    originalTargetPath,
    generatedTargetPath,
    pubspecPath,
    pubspecBackupPath,
    lockPath,
    lockBackupPath,
  ];
}

String _temporaryHelperCanonicalProject(String path) {
  final absolute = _absoluteNormalized(path);
  if (!_temporaryHelperValidAbsolutePath(absolute)) {
    throw const ScoutCliException(
      'temporary_helper_project_path_invalid',
      'The temporary-helper project path is not absolute and bounded.',
    );
  }
  final type = FileSystemEntity.typeSync(absolute, followLinks: false);
  if (type != FileSystemEntityType.directory &&
      type != FileSystemEntityType.link) {
    throw const ScoutCliException(
      'temporary_helper_project_missing',
      'The temporary-helper project directory does not exist.',
    );
  }
  final resolved = Directory(absolute).resolveSymbolicLinksSync();
  if (!_temporaryHelperValidAbsolutePath(resolved) ||
      FileSystemEntity.typeSync(resolved, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw const ScoutCliException(
      'temporary_helper_project_path_invalid',
      'The project path did not resolve to a bounded real directory.',
    );
  }
  return _absoluteNormalized(resolved);
}

bool _temporaryHelperValidAbsolutePath(String value) =>
    value.isNotEmpty &&
    value.length <= _temporaryHelperMaxPathCharacters &&
    p.isAbsolute(value) &&
    !value.contains('\u0000') &&
    _absoluteNormalized(value) == value;

void _temporaryHelperRequireRegularFile(
  String path, {
  required String code,
  required String message,
}) {
  if (!_temporaryHelperValidAbsolutePath(_absoluteNormalized(path)) ||
      FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file) {
    throw ScoutCliException(code, message);
  }
}

List<int> _temporaryHelperReadBoundedFile(File file, {required String label}) {
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw ScoutCliException(
      'temporary_helper_file_unsafe',
      '$label is not a regular file.',
    );
  }
  final length = file.lengthSync();
  if (length < 0 || length > _temporaryHelperMaxTrackedBytes) {
    throw ScoutCliException(
      'temporary_helper_file_too_large',
      '$label exceeds the bounded temporary-helper input limit.',
    );
  }
  return file.readAsBytesSync();
}

List<int>? _temporaryHelperReadOptionalRegularFile(
  String path, {
  required String label,
}) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return null;
  if (type != FileSystemEntityType.file) {
    throw _TemporaryHelperRepairConflict(
      'tracked_path_is_not_regular',
      <Map<String, Object?>>[
        <String, Object?>{
          'path': path,
          'expected': 'regular_file_or_absent',
          'actual': '$type',
        },
      ],
    );
  }
  return _temporaryHelperReadBoundedFile(File(path), label: label);
}

void _temporaryHelperWriteRecord(String path, Map<String, Object?> record) {
  record['updatedAt'] = DateTime.now().toUtc().toIso8601String();
  record.remove('recordIntegritySha256');
  record['recordIntegritySha256'] = crypto.sha256
      .convert(utf8.encode(_temporaryHelperCanonicalJson(record)))
      .toString();
  final scoutRoot = record['scoutRoot']?.toString();
  if (scoutRoot == null ||
      !_temporaryHelperValidAbsolutePath(scoutRoot) ||
      (path != scoutRoot && !p.isWithin(scoutRoot, path))) {
    throw const ScoutCliException(
      'temporary_helper_record_path_invalid',
      'The repair record escapes its exact private Scout root.',
    );
  }
  final encoded = const JsonEncoder.withIndent(' ').convert(record);
  if (utf8.encode(encoded).length > _temporaryHelperMaxRecordBytes) {
    throw const ScoutCliException(
      'temporary_helper_record_too_large',
      'The repair record exceeds its strict size bound.',
    );
  }
  _atomicWritePrivateString(path, encoded, boundary: scoutRoot);
  // Atomic private writes flush the temporary inode before rename. Flush the
  // named inode too so the write-ahead record is durable before tracked input
  // mutation begins.
  final handle = File(path).openSync(mode: FileMode.append);
  try {
    handle.flushSync();
  } finally {
    handle.closeSync();
  }
}

void _temporaryHelperSetPhase(Map<String, Object?> record, String phase) {
  record['phase'] = phase;
  record['updatedAt'] = DateTime.now().toUtc().toIso8601String();
}

Map<String, Object?> _temporaryHelperReadAndValidateRecord(
  String requestedPath, {
  bool completedTombstone = false,
}) {
  final path = _absoluteNormalized(requestedPath);
  if (!_temporaryHelperValidAbsolutePath(path) ||
      FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file) {
    throw const ScoutCliException(
      'temporary_helper_record_missing',
      'The temporary-helper repair record is missing or not regular.',
    );
  }
  final file = File(path);
  if (file.lengthSync() > _temporaryHelperMaxRecordBytes) {
    throw const ScoutCliException(
      'temporary_helper_record_too_large',
      'The temporary-helper repair record exceeds its strict size bound.',
    );
  }
  late final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(file.readAsBytesSync()));
  } catch (_) {
    throw const ScoutCliException(
      'temporary_helper_record_corrupt',
      'The temporary-helper repair record is not valid UTF-8 JSON.',
    );
  }
  if (decoded is! Map) {
    throw const ScoutCliException(
      'temporary_helper_record_corrupt',
      'The temporary-helper repair record is not a JSON object.',
    );
  }
  final record = Map<String, Object?>.from(decoded);
  if (record['schemaVersion'] != _temporaryHelperRecordSchemaVersion ||
      record['kind'] != 'flutter_scout_temporary_helper_repair') {
    throw const ScoutCliException(
      'temporary_helper_record_schema_invalid',
      'The repair record schema or kind is unsupported.',
    );
  }
  final integrity = record.remove('recordIntegritySha256')?.toString();
  final expectedIntegrity = crypto.sha256
      .convert(utf8.encode(_temporaryHelperCanonicalJson(record)))
      .toString();
  record['recordIntegritySha256'] = integrity;
  if (integrity == null || integrity != expectedIntegrity) {
    throw const ScoutCliException(
      'temporary_helper_record_integrity_failed',
      'The repair record integrity digest does not match its contents.',
    );
  }
  final transactionId = record['transactionId']?.toString();
  if (transactionId == null ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(transactionId)) {
    throw const ScoutCliException(
      'temporary_helper_record_identity_invalid',
      'The repair record transaction identity is invalid.',
    );
  }
  const pathKeys = <String>[
    'sessionDirectory',
    'projectPath',
    'scoutRoot',
    'transactionDirectory',
    'recordPath',
    'helperPath',
    'originalTargetPath',
    'generatedTargetPath',
    'pubspecPath',
    'pubspecBackupPath',
    'lockPath',
  ];
  for (final key in pathKeys) {
    final value = record[key]?.toString();
    if (value == null || !_temporaryHelperValidAbsolutePath(value)) {
      throw const ScoutCliException(
        'temporary_helper_record_path_invalid',
        'The repair record contains an invalid path.',
      );
    }
  }
  final lockBackup = record['lockBackupPath'];
  if (lockBackup != null &&
      !_temporaryHelperValidAbsolutePath(lockBackup.toString())) {
    throw const ScoutCliException(
      'temporary_helper_record_path_invalid',
      'The repair record contains an invalid lock backup path.',
    );
  }
  final project = record['projectPath']! as String;
  final scoutRoot = record['scoutRoot']! as String;
  final transactionDir = record['transactionDirectory']! as String;
  final recordedPath = record['recordPath']! as String;
  if (_temporaryHelperCanonicalProject(project) != project ||
      scoutRoot != p.join(project, '.flutter_scout') ||
      transactionDir !=
          p.join(
            scoutRoot,
            'temporary_helper',
            'transactions',
            transactionId,
          ) ||
      recordedPath != p.join(transactionDir, 'repair.json') ||
      record['generatedTargetPath'] !=
          p.join(scoutRoot, 'bootstrap_$transactionId.dart') ||
      record['pubspecPath'] != p.join(project, 'pubspec.yaml') ||
      record['lockPath'] != p.join(project, 'pubspec.lock') ||
      record['pubspecBackupPath'] !=
          p.join(transactionDir, 'pubspec.yaml.original') ||
      (record['lockBackupPath'] != null &&
          record['lockBackupPath'] !=
              p.join(transactionDir, 'pubspec.lock.original')) ||
      !p.isWithin(project, record['originalTargetPath']! as String)) {
    throw const ScoutCliException(
      'temporary_helper_record_path_mismatch',
      'The repair record paths do not match the exact derived restore plan.',
    );
  }
  if (!completedTombstone && path != recordedPath) {
    throw const ScoutCliException(
      'temporary_helper_record_path_mismatch',
      'The repair record was moved outside its exact transaction directory.',
    );
  }
  if (completedTombstone &&
      (!p.basename(p.dirname(path)).startsWith('.completed_$transactionId') ||
          p.dirname(p.dirname(path)) != p.dirname(transactionDir))) {
    throw const ScoutCliException(
      'temporary_helper_tombstone_path_invalid',
      'The completed repair tombstone is outside its exact collection.',
    );
  }
  final digestKeys = <String>[
    'generatedTargetSha256',
    'pubspecOriginalSha256',
    'pubspecInjectedSha256',
    if (record['lockOriginalSha256'] != null) 'lockOriginalSha256',
    if (record['helperLockSha256'] != null) 'helperLockSha256',
    if (record['cleanupLockSha256'] != null) 'cleanupLockSha256',
  ];
  for (final key in digestKeys) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(record[key]?.toString() ?? '')) {
      throw const ScoutCliException(
        'temporary_helper_record_digest_invalid',
        'The repair record contains an invalid SHA-256 digest.',
      );
    }
  }
  _assertNoManagedLinks(
    scoutRoot,
    path,
    finalMayBeFile: true,
    allowMissing: false,
  );
  return record;
}

String _temporaryHelperCanonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return '{${[for (final key in keys) '${jsonEncode(key)}:${_temporaryHelperCanonicalJson(value[key])}'].join(',')}}';
  }
  if (value is Iterable) {
    return '[${value.map(_temporaryHelperCanonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}

void _temporaryHelperAtomicReplaceTrackedFile({
  required String path,
  required List<int> bytes,
  required String expectedCurrentSha256,
  required String projectRoot,
}) {
  final target = _absoluteNormalized(path);
  final project = _absoluteNormalized(projectRoot);
  if (!p.isWithin(project, target) && target != project) {
    throw const ScoutCliException(
      'temporary_helper_tracked_path_outside_project',
      'A tracked restore path escapes the exact project.',
    );
  }
  _assertNoManagedLinks(
    project,
    target,
    finalMayBeFile: true,
    allowMissing: false,
  );
  final current = _temporaryHelperReadBoundedFile(
    File(target),
    label: p.basename(target),
  );
  final currentSha = crypto.sha256.convert(current).toString();
  if (currentSha != expectedCurrentSha256) {
    throw _TemporaryHelperRepairConflict(
      'tracked_input_changed',
      <Map<String, Object?>>[
        <String, Object?>{
          'path': target,
          'expectedCurrentSha256': expectedCurrentSha256,
          'actualSha256': currentSha,
          'action': 'preserved_without_overwrite',
        },
      ],
    );
  }
  final mode = FileStat.statSync(target).mode & 0x1ff;
  final parent = p.dirname(target);
  final temporary = File(
    p.join(
      parent,
      '.${p.basename(target)}.flutter_scout.$pid.'
      '${DateTime.now().microsecondsSinceEpoch}.'
      '${Random.secure().nextInt(0x7fffffff)}.tmp',
    ),
  );
  RandomAccessFile? handle;
  try {
    if (FileSystemEntity.typeSync(temporary.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const ScoutCliException(
        'temporary_helper_atomic_temp_collision',
        'A temporary tracked-file path unexpectedly already exists.',
      );
    }
    temporary.createSync(exclusive: true);
    if (_supportsPosixModes) {
      final chmod = Process.runSync('chmod', <String>[
        mode.toRadixString(8).padLeft(3, '0'),
        temporary.path,
      ]);
      if (chmod.exitCode != 0) {
        throw const ScoutCliException(
          'temporary_helper_mode_preservation_failed',
          'Could not preserve tracked-file permissions during atomic restore.',
        );
      }
    }
    handle = temporary.openSync(mode: FileMode.write);
    handle.writeFromSync(bytes);
    handle.flushSync();
    handle.closeSync();
    handle = null;
    _assertNoManagedLinks(
      project,
      target,
      finalMayBeFile: true,
      allowMissing: false,
    );
    final immediatelyBefore = crypto.sha256
        .convert(File(target).readAsBytesSync())
        .toString();
    if (immediatelyBefore != expectedCurrentSha256) {
      throw _TemporaryHelperRepairConflict(
        'tracked_input_changed_during_restore',
        <Map<String, Object?>>[
          <String, Object?>{
            'path': target,
            'expectedCurrentSha256': expectedCurrentSha256,
            'actualSha256': immediatelyBefore,
            'action': 'preserved_without_overwrite',
          },
        ],
      );
    }
    temporary.renameSync(target);
    final finalHandle = File(target).openSync(mode: FileMode.append);
    try {
      finalHandle.flushSync();
    } finally {
      finalHandle.closeSync();
    }
  } finally {
    try {
      handle?.closeSync();
    } catch (_) {}
    try {
      if (temporary.existsSync()) temporary.deleteSync();
    } catch (_) {}
  }
}

Map<String, Object?> _temporaryHelperRestorePubspec(
  Map<String, Object?> record,
) {
  final path = record['pubspecPath']! as String;
  final backupPath = record['pubspecBackupPath']! as String;
  final originalSha = record['pubspecOriginalSha256']! as String;
  final injectedSha = record['pubspecInjectedSha256']! as String;
  final backup = _temporaryHelperReadBoundedFile(
    File(backupPath),
    label: 'private pubspec backup',
  );
  if (crypto.sha256.convert(backup).toString() != originalSha) {
    throw _TemporaryHelperRepairConflict(
      'pubspec_backup_digest_mismatch',
      <Map<String, Object?>>[
        <String, Object?>{
          'path': backupPath,
          'expectedSha256': originalSha,
          'action': 'repair_stopped_without_overwrite',
        },
      ],
    );
  }
  final current = _temporaryHelperReadOptionalRegularFile(
    path,
    label: 'pubspec.yaml during repair',
  );
  if (current == null) {
    throw _TemporaryHelperRepairConflict(
      'pubspec_missing_during_repair',
      <Map<String, Object?>>[
        <String, Object?>{
          'path': path,
          'expectedSha256': originalSha,
          'actual': 'missing',
          'action': 'preserved_without_overwrite',
        },
      ],
    );
  }
  final currentSha = crypto.sha256.convert(current).toString();
  if (currentSha == originalSha) {
    return <String, Object?>{
      'path': path,
      'status': 'already_original',
      'sha256': currentSha,
    };
  }
  if (currentSha != injectedSha) {
    throw _TemporaryHelperRepairConflict(
      'pubspec_changed_since_transaction',
      <Map<String, Object?>>[
        <String, Object?>{
          'path': path,
          'expectedOwnedSha256': <Object?>[originalSha, injectedSha],
          'actualSha256': currentSha,
          'action': 'preserved_without_overwrite',
        },
      ],
    );
  }
  _temporaryHelperAtomicReplaceTrackedFile(
    path: path,
    bytes: backup,
    expectedCurrentSha256: currentSha,
    projectRoot: record['projectPath']! as String,
  );
  return <String, Object?>{
    'path': path,
    'status': 'restored_from_private_backup',
    'sha256': originalSha,
  };
}

Map<String, Object?> _temporaryHelperRestoreLock(Map<String, Object?> record) {
  final path = record['lockPath']! as String;
  final originallyExisted = record['lockOriginallyExisted'] == true;
  final current = _temporaryHelperReadOptionalRegularFile(
    path,
    label: 'pubspec.lock during repair',
  );
  final currentSha = current == null
      ? null
      : crypto.sha256.convert(current).toString();
  final allowedOwnedDigests = <String>{
    for (final key in const <String>['helperLockSha256', 'cleanupLockSha256'])
      if (record[key] != null) record[key]!.toString(),
  };
  if (originallyExisted) {
    final originalSha = record['lockOriginalSha256']?.toString();
    final backupPath = record['lockBackupPath']?.toString();
    if (originalSha == null || backupPath == null) {
      throw const _TemporaryHelperRepairConflict(
        'lock_restore_plan_incomplete',
        <Map<String, Object?>>[],
      );
    }
    final backup = _temporaryHelperReadBoundedFile(
      File(backupPath),
      label: 'private pubspec.lock backup',
    );
    if (crypto.sha256.convert(backup).toString() != originalSha) {
      throw _TemporaryHelperRepairConflict(
        'lock_backup_digest_mismatch',
        <Map<String, Object?>>[
          <String, Object?>{
            'path': backupPath,
            'expectedSha256': originalSha,
            'action': 'repair_stopped_without_overwrite',
          },
        ],
      );
    }
    if (currentSha == originalSha) {
      return <String, Object?>{
        'path': path,
        'status': 'already_original',
        'sha256': originalSha,
      };
    }
    if (currentSha == null || !allowedOwnedDigests.contains(currentSha)) {
      throw _TemporaryHelperRepairConflict(
        'lock_changed_since_transaction',
        <Map<String, Object?>>[
          <String, Object?>{
            'path': path,
            'expectedOwnedSha256': <Object?>[
              originalSha,
              ...allowedOwnedDigests,
            ],
            'actualSha256': currentSha,
            'actual': currentSha == null ? 'missing' : 'regular_file',
            'action': 'preserved_without_overwrite',
          },
        ],
      );
    }
    _temporaryHelperAtomicReplaceTrackedFile(
      path: path,
      bytes: backup,
      expectedCurrentSha256: currentSha,
      projectRoot: record['projectPath']! as String,
    );
    return <String, Object?>{
      'path': path,
      'status': 'restored_from_private_backup',
      'sha256': originalSha,
    };
  }
  if (current == null) {
    return <String, Object?>{'path': path, 'status': 'already_absent'};
  }
  if (!allowedOwnedDigests.contains(currentSha)) {
    throw _TemporaryHelperRepairConflict(
      'new_lock_not_owned_by_transaction',
      <Map<String, Object?>>[
        <String, Object?>{
          'path': path,
          'expectedOwnedSha256': allowedOwnedDigests.toList()..sort(),
          'actualSha256': currentSha,
          'action': 'preserved_without_delete',
        },
      ],
    );
  }
  // Revalidate immediately before deletion. Missing is already the desired
  // state, while any changed digest fails closed.
  final immediatelyBefore = _temporaryHelperReadOptionalRegularFile(
    path,
    label: 'pubspec.lock immediately before deletion',
  );
  if (immediatelyBefore != null &&
      crypto.sha256.convert(immediatelyBefore).toString() != currentSha) {
    throw _TemporaryHelperRepairConflict(
      'lock_changed_during_restore',
      <Map<String, Object?>>[
        <String, Object?>{'path': path, 'action': 'preserved_without_delete'},
      ],
    );
  }
  if (immediatelyBefore != null) File(path).deleteSync();
  return <String, Object?>{
    'path': path,
    'status': 'transaction_created_lock_removed',
    'sha256': currentSha,
  };
}

Map<String, Object?> _temporaryHelperRemoveGeneratedTarget(
  Map<String, Object?> record,
) {
  final path = record['generatedTargetPath']! as String;
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    return <String, Object?>{'path': path, 'status': 'already_absent'};
  }
  if (type != FileSystemEntityType.file) {
    throw _TemporaryHelperRepairConflict(
      'generated_target_not_regular',
      <Map<String, Object?>>[
        <String, Object?>{
          'path': path,
          'expected': 'regular_file_or_absent',
          'actual': '$type',
          'action': 'preserved_without_delete',
        },
      ],
    );
  }
  final expected = record['generatedTargetSha256']! as String;
  final actual = crypto.sha256.convert(File(path).readAsBytesSync()).toString();
  if (actual != expected) {
    throw _TemporaryHelperRepairConflict(
      'generated_target_changed_since_transaction',
      <Map<String, Object?>>[
        <String, Object?>{
          'path': path,
          'expectedOwnedSha256': expected,
          'actualSha256': actual,
          'action': 'preserved_without_delete',
        },
      ],
    );
  }
  final scoutRoot = record['scoutRoot']! as String;
  _assertNoManagedLinks(
    scoutRoot,
    path,
    finalMayBeFile: true,
    allowMissing: false,
  );
  final immediatelyBefore = crypto.sha256
      .convert(File(path).readAsBytesSync())
      .toString();
  if (immediatelyBefore != expected) {
    throw _TemporaryHelperRepairConflict(
      'generated_target_changed_during_cleanup',
      <Map<String, Object?>>[
        <String, Object?>{'path': path, 'action': 'preserved_without_delete'},
      ],
    );
  }
  File(path).deleteSync();
  return <String, Object?>{
    'path': path,
    'status': 'transaction_generated_target_removed',
    'sha256': expected,
  };
}

void _temporaryHelperVerifyTrackedInputs(Map<String, Object?> record) {
  final pubspec = _temporaryHelperReadOptionalRegularFile(
    record['pubspecPath']! as String,
    label: 'pubspec.yaml verification',
  );
  final expectedPubspec = record['pubspecOriginalSha256']! as String;
  final pubspecSha = pubspec == null
      ? null
      : crypto.sha256.convert(pubspec).toString();
  final conflicts = <Map<String, Object?>>[];
  if (pubspecSha != expectedPubspec) {
    conflicts.add(<String, Object?>{
      'path': record['pubspecPath'],
      'expectedSha256': expectedPubspec,
      'actualSha256': pubspecSha,
    });
  }
  final lock = _temporaryHelperReadOptionalRegularFile(
    record['lockPath']! as String,
    label: 'pubspec.lock verification',
  );
  final lockSha = lock == null ? null : crypto.sha256.convert(lock).toString();
  if (record['lockOriginallyExisted'] == true) {
    if (lockSha != record['lockOriginalSha256']) {
      conflicts.add(<String, Object?>{
        'path': record['lockPath'],
        'expectedSha256': record['lockOriginalSha256'],
        'actualSha256': lockSha,
      });
    }
  } else if (lock != null) {
    conflicts.add(<String, Object?>{
      'path': record['lockPath'],
      'expected': 'absent',
      'actualSha256': lockSha,
    });
  }
  if (conflicts.isNotEmpty) {
    throw _TemporaryHelperRepairConflict(
      'tracked_input_verification_failed',
      conflicts,
    );
  }
}

Map<String, Object?> _temporaryHelperBlockedReport({
  required String project,
  required String reason,
  required String message,
  String? recordPath,
  List<Map<String, Object?>> conflicts = const <Map<String, Object?>>[],
}) {
  final action = _temporaryHelperPrioritizedAction(
    project,
    recordPath: recordPath,
    reason: reason,
  );
  return <String, Object?>{
    'status': 'repair_required',
    'priority': 'critical',
    'automaticRepair': 'refused',
    'project': _absoluteNormalized(project),
    'reason': reason,
    'message': _temporaryHelperBoundedText(message),
    if (recordPath != null) 'recordPath': _absoluteNormalized(recordPath),
    if (conflicts.isNotEmpty) 'conflicts': conflicts,
    'trackedInputsOverwritten': false,
    'prioritizedRecoveryAction': action,
  };
}

Map<String, Object?> _temporaryHelperPrioritizedAction(
  String project, {
  required String? recordPath,
  required String reason,
}) => <String, Object?>{
  'priority': 0,
  'kind': 'temporary_helper_repair',
  'automatic': false,
  'reason': reason,
  'command': 'flutter-scout doctor --project ${_absoluteNormalized(project)}',
  if (recordPath != null) 'repairRecord': _absoluteNormalized(recordPath),
  'instruction':
      'Review the reported digest conflict. Restore or preserve the user '
      'version intentionally, then rerun doctor. Scout will never overwrite '
      'a digest it cannot prove belongs to its transaction.',
};

String _temporaryHelperBoundedText(String value) =>
    value.length <= 2048 ? value : '${value.substring(0, 2048)}<truncated>';

String _temporaryHelperProjectFromRecordPath(String recordPath) {
  var cursor = _absoluteNormalized(recordPath);
  for (var index = 0; index < 5; index += 1) {
    cursor = p.dirname(cursor);
  }
  return cursor;
}

Map<String, Object?>? _temporaryHelperReadLastRepair(String scoutRoot) {
  final path = p.join(scoutRoot, 'temporary_helper', 'last_repair.json');
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.file) {
    return null;
  }
  try {
    final file = File(path);
    if (file.lengthSync() > _temporaryHelperMaxRecordBytes) return null;
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map || decoded['schemaVersion'] != 1) return null;
    return Map<String, Object?>.from(decoded);
  } catch (_) {
    return null;
  }
}

Map<String, Object?> _temporaryHelperFinalizeCompletedDirectory(
  String directory, {
  required String scoutRoot,
  required String project,
}) {
  final recordPath = p.join(directory, 'repair.json');
  try {
    final record = _temporaryHelperReadAndValidateRecord(
      recordPath,
      completedTombstone: true,
    );
    if (record['phase'] != 'cleanup_committing' ||
        record['projectPath'] != project ||
        record['scoutRoot'] != scoutRoot) {
      throw const ScoutCliException(
        'temporary_helper_tombstone_not_committed',
        'A completed-directory tombstone lacks a committed repair phase.',
      );
    }
    _temporaryHelperVerifyTrackedInputs(record);
    if (FileSystemEntity.typeSync(
          record['generatedTargetPath']! as String,
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound) {
      throw const ScoutCliException(
        'temporary_helper_tombstone_target_present',
        'A committed cleanup tombstone still has a generated target.',
      );
    }
    _deletePrivateDirectoryIfExists(directory, boundary: scoutRoot);
    return <String, Object?>{
      'status': 'repaired',
      'transactionId': record['transactionId'],
      'phase': 'completed_tombstone_removed',
      'trackedInputsVerified': true,
    };
  } on ScoutCliException catch (error) {
    return <String, Object?>{
      'status': 'repair_required',
      'reason': error.code,
      'message': error.message,
      'transactionDirectory': _absoluteNormalized(directory),
    };
  } on _TemporaryHelperRepairConflict catch (error) {
    return <String, Object?>{
      'status': 'repair_required',
      'reason': error.code,
      'conflicts': error.conflicts,
      'transactionDirectory': _absoluteNormalized(directory),
    };
  }
}
