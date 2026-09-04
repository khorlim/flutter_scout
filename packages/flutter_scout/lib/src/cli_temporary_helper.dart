part of 'flutter_scout_cli.dart';

// Crash-safe, project-local write-ahead log for temporary-helper setup.
//
// This is deliberately separate from session_meta.json. Setup changes the app
// project before a VM service exists, so a killed launch must remain repairable
// even when no session metadata was ever committed.

const int _temporaryHelperRecordSchemaVersion = 1;
const int _temporaryHelperMaxRecordBytes = 128 * 1024;
const int _temporaryHelperMaxTrackedBytes = 16 * 1024 * 1024;
const int _temporaryHelperMaxPathCharacters = 4096;
const int _temporaryHelperMaxTransactions = 64;
const String _temporaryHelperOwnerRole = 'temporary_helper_cli';

final class _TemporaryHelperSimulatedInterruption implements Exception {
  const _TemporaryHelperSimulatedInterruption(this.phase);

  final String phase;
}

final class _TemporaryHelperRepairConflict implements Exception {
  const _TemporaryHelperRepairConflict(this.code, this.conflicts);

  final String code;
  final List<Map<String, Object?>> conflicts;
}

extension _CliTemporaryHelper on FlutterScoutCli {
  Future<_TemporaryHelperSetup> _prepareTemporaryHelper({
    required String project,
    required String originalTarget,
    required String? helperPath,
    required String runId,
  }) async {
    final paths = await _temporaryHelperValidatedPaths(
      project: project,
      originalTarget: originalTarget,
      helperPath: helperPath,
      runId: runId,
    );
    final pubspec = File(paths.pubspecPath);
    final originalPubspec = _temporaryHelperReadBoundedFile(
      pubspec,
      label: 'pubspec.yaml',
    );
    final pubspecText = utf8.decode(originalPubspec, allowMalformed: false);
    final dependencyAlreadyPresent = RegExp(
      r'^\s*flutter_scout_helper\s*:',
      multiLine: true,
    ).hasMatch(pubspecText);
    var injectedPubspec = originalPubspec;
    if (!dependencyAlreadyPresent) {
      final dependencies = RegExp(
        r'^dependencies:\s*$',
        multiLine: true,
      ).firstMatch(pubspecText);
      if (dependencies == null) {
        throw const ScoutCliException(
          'temporary_helper_dependencies_missing',
          'pubspec.yaml has no top-level dependencies section.',
        );
      }
      final quotedPath = paths.helperPath.replaceAll("'", "''");
      final insertion = "\n  flutter_scout_helper:\n    path: '$quotedPath'";
      injectedPubspec = utf8.encode(
        pubspecText.replaceRange(dependencies.end, dependencies.end, insertion),
      );
    }

    final lockFile = File(paths.lockPath);
    final lockType = FileSystemEntity.typeSync(
      lockFile.path,
      followLinks: false,
    );
    if (lockType != FileSystemEntityType.notFound &&
        lockType != FileSystemEntityType.file) {
      throw const ScoutCliException(
        'temporary_helper_lock_unsafe',
        'pubspec.lock must be absent or a regular file; symbolic links and '
            'special filesystem objects are refused.',
      );
    }
    final originalLock = lockType == FileSystemEntityType.file
        ? _temporaryHelperReadBoundedFile(lockFile, label: 'pubspec.lock')
        : null;
    final relativeTarget = p
        .relative(paths.originalTargetPath, from: paths.scoutRoot)
        .split(p.separator)
        .join('/');
    final generatedTargetBytes = utf8.encode('''
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import '$relativeTarget' as app;

Future<void> main() async {
  FlutterScoutBinding.ensureInitialized();
  await Future<void>.sync(app.main);
}

''');

    _ensurePrivateDirectory(paths.transactionDir, boundary: paths.scoutRoot);
    _atomicWritePrivateBytes(
      paths.pubspecBackupPath,
      originalPubspec,
      boundary: paths.scoutRoot,
    );
    if (originalLock != null) {
      _atomicWritePrivateBytes(
        paths.lockBackupPath,
        originalLock,
        boundary: paths.scoutRoot,
      );
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final ownerIdentity = await _readProcessOwnershipIdentity(
      pid,
      role: _temporaryHelperOwnerRole,
    );
    final record = <String, Object?>{
      'schemaVersion': _temporaryHelperRecordSchemaVersion,
      'kind': 'flutter_scout_temporary_helper_repair',
      'transactionId': paths.transactionId,
      'runId': runId,
      'commandId': _activeCommandId,
      'phase': 'record_prepared',
      'createdAt': now,
      'updatedAt': now,
      'ownerProcessId': pid,
      'ownerProcessIdentity': ownerIdentity,
      'sessionDirectory': _absoluteNormalized(_sessionDir.path),
      'projectPath': paths.projectPath,
      'scoutRoot': paths.scoutRoot,
      'transactionDirectory': paths.transactionDir,
      'recordPath': paths.recordPath,
      'helperPath': paths.helperPath,
      'originalTargetPath': paths.originalTargetPath,
      'generatedTargetPath': paths.generatedTargetPath,
      'generatedTargetSha256': crypto.sha256
          .convert(generatedTargetBytes)
          .toString(),
      'pubspecPath': paths.pubspecPath,
      'pubspecBackupPath': paths.pubspecBackupPath,
      'pubspecOriginalSha256': crypto.sha256
          .convert(originalPubspec)
          .toString(),
      'pubspecInjectedSha256': crypto.sha256
          .convert(injectedPubspec)
          .toString(),
      'dependencyInjected': !dependencyAlreadyPresent,
      'lockPath': paths.lockPath,
      'lockOriginallyExisted': originalLock != null,
      'lockBackupPath': originalLock == null ? null : paths.lockBackupPath,
      'lockOriginalSha256': originalLock == null
          ? null
          : crypto.sha256.convert(originalLock).toString(),
      'helperLockExisted': null,
      'helperLockSha256': null,
      'cleanupLockExisted': null,
      'cleanupLockSha256': null,
      'restorePlan': <Object?>[
        <String, Object?>{
          'order': 1,
          'operation': 'restore_exact_file_from_private_backup',
          'path': paths.pubspecPath,
          'backupPath': paths.pubspecBackupPath,
          'originalSha256': crypto.sha256.convert(originalPubspec).toString(),
        },
        <String, Object?>{
          'order': 2,
          'operation': originalLock == null
              ? 'delete_only_if_transaction_digest_matches'
              : 'restore_exact_file_from_private_backup',
          'path': paths.lockPath,
          'backupPath': originalLock == null ? null : paths.lockBackupPath,
          'originalSha256': originalLock == null
              ? null
              : crypto.sha256.convert(originalLock).toString(),
        },
        <String, Object?>{
          'order': 3,
          'operation': 'delete_only_if_transaction_digest_matches',
          'path': paths.generatedTargetPath,
          'sha256': crypto.sha256.convert(generatedTargetBytes).toString(),
        },
        <String, Object?>{
          'order': 4,
          'operation': 'flutter_pub_get_with_original_tracked_inputs',
          'workingDirectory': paths.projectPath,
        },
        <String, Object?>{
          'order': 5,
          'operation': 'verify_original_sha256_or_absence',
          'paths': <Object?>[paths.pubspecPath, paths.lockPath],
        },
      ],
      'repair': <String, Object?>{
        'status': 'pending',
        'automatic': true,
        'priority': 'critical',
      },
    };
    _temporaryHelperWriteRecord(paths.recordPath, record);
    _temporaryHelperCheckpoint('record_prepared');

    try {
      if (!dependencyAlreadyPresent) {
        _temporaryHelperSetPhase(record, 'pubspec_write_started');
        _temporaryHelperWriteRecord(paths.recordPath, record);
        _temporaryHelperCheckpoint('pubspec_write_started');
        _temporaryHelperAtomicReplaceTrackedFile(
          path: paths.pubspecPath,
          bytes: injectedPubspec,
          expectedCurrentSha256: record['pubspecOriginalSha256']! as String,
          projectRoot: paths.projectPath,
        );
      }
      _temporaryHelperSetPhase(record, 'pubspec_injected');
      _temporaryHelperWriteRecord(paths.recordPath, record);
      _temporaryHelperCheckpoint('pubspec_injected');

      _temporaryHelperSetPhase(record, 'helper_pub_get_started');
      _temporaryHelperWriteRecord(paths.recordPath, record);
      _temporaryHelperCheckpoint('helper_pub_get_started');
      final pubGet = await _runTemporaryHelperPubGet(paths.projectPath);
      final helperLock = _temporaryHelperReadOptionalRegularFile(
        paths.lockPath,
        label: 'pubspec.lock after helper pub get',
      );
      record['helperLockExisted'] = helperLock != null;
      record['helperLockSha256'] = helperLock == null
          ? null
          : crypto.sha256.convert(helperLock).toString();
      _temporaryHelperSetPhase(
        record,
        pubGet.exitCode == 0
            ? 'helper_pub_get_completed'
            : 'helper_pub_get_failed',
      );
      _temporaryHelperWriteRecord(paths.recordPath, record);
      _temporaryHelperCheckpoint(record['phase']! as String);
      if (pubGet.exitCode != 0) {
        throw ScoutCliException(
          'temporary_helper_pub_get_failed',
          'flutter pub get failed during temporary helper setup: '
              '${pubGet.stderr}',
        );
      }

      _temporaryHelperSetPhase(record, 'target_write_started');
      _temporaryHelperWriteRecord(paths.recordPath, record);
      _temporaryHelperCheckpoint('target_write_started');
      _atomicWritePrivateBytes(
        paths.generatedTargetPath,
        generatedTargetBytes,
        boundary: paths.scoutRoot,
      );
      _temporaryHelperSetPhase(record, 'target_written');
      _temporaryHelperWriteRecord(paths.recordPath, record);
      _temporaryHelperCheckpoint('target_written');

      _temporaryHelperRestorePubspec(record);
      _temporaryHelperSetPhase(record, 'pubspec_restored');
      _temporaryHelperWriteRecord(paths.recordPath, record);
      _temporaryHelperCheckpoint('pubspec_restored');
      _temporaryHelperRestoreLock(record);
      _temporaryHelperSetPhase(record, 'lock_restored');
      _temporaryHelperWriteRecord(paths.recordPath, record);
      _temporaryHelperCheckpoint('lock_restored');
      _temporaryHelperVerifyTrackedInputs(record);
      _temporaryHelperSetPhase(record, 'active');
      record['repair'] = const <String, Object?>{
        'status': 'not_needed_while_owned_session_is_live',
        'automatic': true,
        'priority': 'critical',
      };
      _temporaryHelperWriteRecord(paths.recordPath, record);
      _temporaryHelperCheckpoint('active');
      return _TemporaryHelperSetup(
        project: paths.projectPath,
        targetPath: paths.generatedTargetPath,
        lockExisted: originalLock != null,
        lockBackupPath: originalLock == null ? null : paths.lockBackupPath,
        transactionRecordPath: paths.recordPath,
        transactionId: paths.transactionId,
      );
    } on _TemporaryHelperSimulatedInterruption {
      rethrow;
    } catch (error) {
      final repair = await _repairTemporaryHelperRecord(
        paths.recordPath,
        operation: 'setup_failure',
      );
      if (repair['status'] == 'repaired') rethrow;
      throw ScoutCliException(
        'temporary_helper_repair_required',
        'Temporary helper setup failed and automatic repair could not finish. '
            'Tracked files were not overwritten; inspect the typed repair '
            'record before retrying.',
        details: <String, Object?>{'setupFailure': error.toString()},
        additional: <String, Object?>{
          'temporaryHelperRecovery': repair,
          'prioritizedRecoveryAction': repair['prioritizedRecoveryAction'],
        },
      );
    }
  }

  Future<ProcessResult> _runTemporaryHelperPubGet(String project) {
    final override = FlutterScoutCli.debugTemporaryHelperPubGetOverride;
    if (override != null) return override(project);
    return Process.run(
      'flutter',
      const <String>['pub', 'get'],
      workingDirectory: project,
      environment: _flutterToolEnvironment(),
    );
  }

  void _temporaryHelperCheckpoint(String phase) {
    if (FlutterScoutCli.debugTemporaryHelperInterruptAfterPhase == phase) {
      throw _TemporaryHelperSimulatedInterruption(phase);
    }
  }

  _TemporaryHelperSetup? _temporarySetupFromMeta() {
    final value = _readSessionMeta()?['temporarySetup'];
    if (value is! Map) return null;
    final project = value['project']?.toString();
    final targetPath = value['targetPath']?.toString();
    if (project == null ||
        project.isEmpty ||
        targetPath == null ||
        targetPath.isEmpty) {
      return null;
    }
    return _TemporaryHelperSetup(
      project: project,
      targetPath: targetPath,
      lockExisted: value['lockExisted'] == true,
      lockBackupPath: value['lockBackupPath']?.toString(),
      transactionRecordPath: value['transactionRecordPath']?.toString(),
      transactionId: value['transactionId']?.toString(),
    );
  }

  Future<Map<String, Object?>> _cleanupTemporaryHelper(
    _TemporaryHelperSetup setup,
  ) async {
    final recordPath = setup.transactionRecordPath;
    if (recordPath != null && recordPath.isNotEmpty) {
      final recordType = FileSystemEntity.typeSync(
        recordPath,
        followLinks: false,
      );
      if (recordType == FileSystemEntityType.notFound) {
        final transactionDirectory = p.dirname(recordPath);
        final transactionType = FileSystemEntity.typeSync(
          transactionDirectory,
          followLinks: false,
        );
        final targetType = FileSystemEntity.typeSync(
          setup.targetPath,
          followLinks: false,
        );
        if (transactionType != FileSystemEntityType.notFound ||
            targetType != FileSystemEntityType.notFound) {
          return _temporaryHelperBlockedReport(
            project: setup.project,
            reason: 'repair_record_missing',
            message:
                'The repair record is missing while transaction-owned artifacts still exist.',
            recordPath: recordPath,
          );
        }
        return <String, Object?>{
          'status': 'repaired',
          'alreadyClean': true,
          'operation': 'session_cleanup',
        };
      }
      if (recordType != FileSystemEntityType.file) {
        return _temporaryHelperBlockedReport(
          project: setup.project,
          reason: 'repair_record_not_regular',
          message:
              'The repair record is a symbolic link or special filesystem object.',
          recordPath: recordPath,
        );
      }
      return _repairTemporaryHelperRecord(
        recordPath,
        operation: 'session_cleanup',
      );
    }
    // Backwards compatibility for sessions created before the WAL existed.
    // The generated target can be removed only under the exact project Scout
    // root. The lock is never overwritten without a transaction digest.
    final project = _temporaryHelperCanonicalProject(setup.project);
    final scoutRoot = p.join(project, '.flutter_scout');
    final target = _absoluteNormalized(setup.targetPath);
    var targetRemoved = false;
    if (p.isWithin(scoutRoot, target) &&
        RegExp(
          r'^bootstrap_[A-Za-z0-9._-]+\.dart$',
        ).hasMatch(p.basename(target))) {
      final type = FileSystemEntity.typeSync(target, followLinks: false);
      if (type == FileSystemEntityType.file) {
        File(target).deleteSync();
        targetRemoved = true;
      } else if (type != FileSystemEntityType.notFound) {
        throw const ScoutCliException(
          'temporary_helper_legacy_cleanup_unsafe',
          'The legacy generated target is not a regular file; Scout refused '
              'to delete it.',
        );
      }
    }
    final pubGet = await _runTemporaryHelperPubGet(project);
    return <String, Object?>{
      'status': pubGet.exitCode == 0
          ? 'legacy_cleanup_completed'
          : 'repair_required',
      'legacyRecord': true,
      'targetRemoved': targetRemoved,
      'packageConfigRestored': pubGet.exitCode == 0,
      'lockRestored': false,
      if (pubGet.exitCode != 0) 'pubGetError': '${pubGet.stderr}',
    };
  }

  Future<Map<String, Object?>> _recoverPendingTemporaryHelpersAtCommandStart(
    String command,
    List<String> args,
  ) async {
    if (command == 'flutter-run-worker' || command == 'vm-log-listener') {
      return const <String, Object?>{'status': 'not_applicable'};
    }
    final candidates = <String>{};
    final explicitProject = _optionValue(args, 'project');
    if (explicitProject != null && explicitProject.isNotEmpty) {
      candidates.add(_absoluteNormalized(explicitProject));
    }
    final sessionProject = _readSessionMeta()?['project']?.toString();
    if (sessionProject != null && sessionProject.isNotEmpty) {
      candidates.add(_absoluteNormalized(sessionProject));
    }
    final current = _absoluteNormalized(Directory.current.path);
    if (File(p.join(current, 'pubspec.yaml')).existsSync() ||
        FileSystemEntity.typeSync(
              p.join(current, '.flutter_scout', 'temporary_helper'),
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
      candidates.add(current);
    }
    final reports = <Map<String, Object?>>[];
    for (final candidate in candidates.take(8)) {
      if (!Directory(candidate).existsSync()) continue;
      final report = await _recoverTemporaryHelperProject(
        candidate,
        preserveLive: true,
      );
      if (report['status'] != 'clean') reports.add(report);
      if (report['status'] == 'repair_required') {
        if (const <String>{
          'status',
          'doctor',
          'stop',
          'cleanup',
        }.contains(command)) {
          continue;
        }
        throw ScoutCliException(
          'temporary_helper_repair_required',
          'A previous temporary-helper transaction could not be repaired '
              'automatically. Scout will not mutate or launch this project '
              'until the tracked-file conflict is resolved.',
          details: <String, Object?>{
            'project': candidate,
            'reason': report['reason'],
          },
          additional: <String, Object?>{
            'temporaryHelperRecovery': report,
            'prioritizedRecoveryAction': report['prioritizedRecoveryAction'],
          },
        );
      }
    }
    if (reports.isEmpty) return const <String, Object?>{'status': 'clean'};
    return <String, Object?>{
      'status': reports.any((value) => value['status'] == 'repair_required')
          ? 'repair_required'
          : reports.any((value) => value['status'] == 'active')
          ? 'active'
          : 'repaired',
      'projects': reports,
    };
  }

  Future<Map<String, Object?>> _recoverTemporaryHelperProject(
    String requestedProject, {
    required bool preserveLive,
  }) async {
    late final String project;
    try {
      project = _temporaryHelperCanonicalProject(requestedProject);
    } on ScoutCliException catch (error) {
      return _temporaryHelperBlockedReport(
        project: _absoluteNormalized(requestedProject),
        reason: error.code,
        message: error.message,
      );
    }
    final scoutRoot = p.join(project, '.flutter_scout');
    final scoutType = FileSystemEntity.typeSync(scoutRoot, followLinks: false);
    if (scoutType == FileSystemEntityType.notFound) {
      return <String, Object?>{'status': 'clean', 'project': project};
    }
    if (scoutType != FileSystemEntityType.directory) {
      return _temporaryHelperBlockedReport(
        project: project,
        reason: 'unsafe_scout_root',
        message:
            'The project .flutter_scout path is a symbolic link or non-directory.',
      );
    }
    final temporaryRoot = p.join(scoutRoot, 'temporary_helper');
    final temporaryType = FileSystemEntity.typeSync(
      temporaryRoot,
      followLinks: false,
    );
    if (temporaryType == FileSystemEntityType.notFound) {
      return <String, Object?>{
        'status': 'clean',
        'project': project,
        'lastRepair': ?_temporaryHelperReadLastRepair(scoutRoot),
      };
    }
    if (temporaryType != FileSystemEntityType.directory) {
      return _temporaryHelperBlockedReport(
        project: project,
        reason: 'unsafe_transaction_root',
        message:
            'The temporary-helper repair root is a symbolic link or non-directory.',
      );
    }
    final transactionsRoot = p.join(temporaryRoot, 'transactions');
    final transactionsType = FileSystemEntity.typeSync(
      transactionsRoot,
      followLinks: false,
    );
    if (transactionsType == FileSystemEntityType.notFound) {
      return <String, Object?>{
        'status': 'clean',
        'project': project,
        'lastRepair': ?_temporaryHelperReadLastRepair(scoutRoot),
      };
    }
    if (transactionsType != FileSystemEntityType.directory) {
      return _temporaryHelperBlockedReport(
        project: project,
        reason: 'unsafe_transactions_directory',
        message: 'The transaction collection is not a regular directory.',
      );
    }
    final entities =
        Directory(
            transactionsRoot,
          ).listSync(followLinks: false).toList(growable: false)
          ..sort((left, right) => left.path.compareTo(right.path));
    if (entities.length > _temporaryHelperMaxTransactions) {
      return _temporaryHelperBlockedReport(
        project: project,
        reason: 'too_many_transaction_records',
        message:
            'The bounded repair scanner found more than $_temporaryHelperMaxTransactions entries.',
      );
    }
    final repaired = <Map<String, Object?>>[];
    final active = <Map<String, Object?>>[];
    final blocked = <Map<String, Object?>>[];
    for (final entity in entities) {
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (type != FileSystemEntityType.directory) {
        blocked.add(<String, Object?>{
          'reason': 'unexpected_transaction_entry',
          'path': _absoluteNormalized(entity.path),
        });
        continue;
      }
      final name = p.basename(entity.path);
      if (name.startsWith('.completed_')) {
        final result = _temporaryHelperFinalizeCompletedDirectory(
          entity.path,
          scoutRoot: scoutRoot,
          project: project,
        );
        (result['status'] == 'repaired' ? repaired : blocked).add(result);
        continue;
      }
      final recordPath = p.join(entity.path, 'repair.json');
      if (FileSystemEntity.typeSync(recordPath, followLinks: false) !=
          FileSystemEntityType.file) {
        blocked.add(<String, Object?>{
          'reason': 'repair_record_missing',
          'transactionDirectory': _absoluteNormalized(entity.path),
        });
        continue;
      }
      Map<String, Object?> record;
      try {
        record = _temporaryHelperReadAndValidateRecord(recordPath);
      } on ScoutCliException catch (error) {
        blocked.add(<String, Object?>{
          'reason': error.code,
          'recordPath': _absoluteNormalized(recordPath),
        });
        continue;
      }
      if (preserveLive && await _temporaryHelperRecordIsLive(record)) {
        active.add(<String, Object?>{
          'status': 'active',
          'transactionId': record['transactionId'],
          'runId': record['runId'],
          'phase': record['phase'],
          'recordPath': record['recordPath'],
          'repairDeferredReason': 'exact_owner_is_live',
        });
        continue;
      }
      final result = await _repairTemporaryHelperRecord(
        recordPath,
        operation: 'startup_recovery',
      );
      (result['status'] == 'repaired' ? repaired : blocked).add(result);
    }
    if (blocked.isNotEmpty) {
      return _temporaryHelperBlockedReport(
        project: project,
        reason: 'transaction_repair_blocked',
        message:
            'One or more temporary-helper transactions require human review.',
        conflicts: blocked,
      );
    }
    if (active.isNotEmpty) {
      return <String, Object?>{
        'status': 'active',
        'project': project,
        'transactions': active,
        if (repaired.isNotEmpty) 'repairedTransactions': repaired,
      };
    }
    return <String, Object?>{
      'status': repaired.isEmpty ? 'clean' : 'repaired',
      'project': project,
      if (repaired.isNotEmpty) 'transactions': repaired,
      'lastRepair': ?_temporaryHelperReadLastRepair(scoutRoot),
    };
  }

  Future<Map<String, Object?>> _repairTemporaryHelperRecord(
    String recordPath, {
    required String operation,
  }) async {
    final absoluteRecordPath = _absoluteNormalized(recordPath);
    if (FileSystemEntity.typeSync(absoluteRecordPath, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return <String, Object?>{
        'status': 'repaired',
        'alreadyClean': true,
        'operation': operation,
      };
    }
    var record = <String, Object?>{};
    try {
      record = _temporaryHelperReadAndValidateRecord(absoluteRecordPath);
      _temporaryHelperSetPhase(record, 'repair_started');
      record['repair'] = <String, Object?>{
        'status': 'running',
        'automatic': true,
        'priority': 'critical',
        'operation': operation,
        'startedAt': DateTime.now().toUtc().toIso8601String(),
      };
      _temporaryHelperWriteRecord(absoluteRecordPath, record);
      _temporaryHelperCheckpoint('repair_started');

      final pubspecResult = _temporaryHelperRestorePubspec(record);
      _temporaryHelperSetPhase(record, 'repair_pubspec_restored');
      _temporaryHelperWriteRecord(absoluteRecordPath, record);
      _temporaryHelperCheckpoint('repair_pubspec_restored');
      final initialLockResult = _temporaryHelperRestoreLock(record);
      _temporaryHelperSetPhase(record, 'repair_lock_restored_before_pub_get');
      _temporaryHelperWriteRecord(absoluteRecordPath, record);
      _temporaryHelperCheckpoint('repair_lock_restored_before_pub_get');
      final targetResult = _temporaryHelperRemoveGeneratedTarget(record);
      _temporaryHelperSetPhase(record, 'repair_target_removed');
      _temporaryHelperWriteRecord(absoluteRecordPath, record);
      _temporaryHelperCheckpoint('repair_target_removed');

      _temporaryHelperVerifyTrackedInputs(record);
      _temporaryHelperSetPhase(record, 'repair_pub_get_started');
      _temporaryHelperWriteRecord(absoluteRecordPath, record);
      _temporaryHelperCheckpoint('repair_pub_get_started');
      final pubGet = await _runTemporaryHelperPubGet(
        record['projectPath']! as String,
      );
      final cleanupLock = _temporaryHelperReadOptionalRegularFile(
        record['lockPath']! as String,
        label: 'pubspec.lock after repair pub get',
      );
      record['cleanupLockExisted'] = cleanupLock != null;
      record['cleanupLockSha256'] = cleanupLock == null
          ? null
          : crypto.sha256.convert(cleanupLock).toString();
      _temporaryHelperSetPhase(
        record,
        pubGet.exitCode == 0
            ? 'repair_pub_get_completed'
            : 'repair_pub_get_failed',
      );
      _temporaryHelperWriteRecord(absoluteRecordPath, record);
      _temporaryHelperCheckpoint(record['phase']! as String);

      final finalLockResult = _temporaryHelperRestoreLock(record);
      _temporaryHelperSetPhase(record, 'repair_final_lock_restored');
      _temporaryHelperWriteRecord(absoluteRecordPath, record);
      _temporaryHelperCheckpoint('repair_final_lock_restored');
      _temporaryHelperVerifyTrackedInputs(record);
      if (pubGet.exitCode != 0) {
        final action = _temporaryHelperPrioritizedAction(
          record['projectPath']! as String,
          recordPath: absoluteRecordPath,
          reason: 'repair_pub_get_failed',
        );
        record['repair'] = <String, Object?>{
          'status': 'repair_required',
          'automatic': false,
          'priority': 'critical',
          'reason': 'repair_pub_get_failed',
          'pubGetError': _temporaryHelperBoundedText('${pubGet.stderr}'),
          'trackedInputsVerified': true,
          'prioritizedRecoveryAction': action,
        };
        _temporaryHelperWriteRecord(absoluteRecordPath, record);
        return <String, Object?>{
          'status': 'repair_required',
          'reason': 'repair_pub_get_failed',
          'recordPath': absoluteRecordPath,
          'trackedInputsVerified': true,
          'packageConfigRestored': false,
          'pubGetError': _temporaryHelperBoundedText('${pubGet.stderr}'),
          'prioritizedRecoveryAction': action,
        };
      }

      final completedAt = DateTime.now().toUtc().toIso8601String();
      final audit = <String, Object?>{
        'schemaVersion': 1,
        'status': 'repaired',
        'operation': operation,
        'transactionId': record['transactionId'],
        'runId': record['runId'],
        'project': record['projectPath'],
        'completedAt': completedAt,
        'trackedInputsVerified': true,
        'packageConfigRestored': true,
        'pubspec': pubspecResult,
        'initialLock': initialLockResult,
        'finalLock': finalLockResult,
        'generatedTarget': targetResult,
      };
      final scoutRoot = record['scoutRoot']! as String;
      final auditPath = p.join(
        scoutRoot,
        'temporary_helper',
        'last_repair.json',
      );
      _atomicWritePrivateJson(auditPath, audit, boundary: scoutRoot);
      _temporaryHelperSetPhase(record, 'cleanup_committing');
      record['repair'] = <String, Object?>{
        'status': 'repaired',
        'automatic': true,
        'priority': 'critical',
        'completedAt': completedAt,
        'trackedInputsVerified': true,
      };
      _temporaryHelperWriteRecord(absoluteRecordPath, record);
      _temporaryHelperCheckpoint('cleanup_committing');
      final transactionDir = record['transactionDirectory']! as String;
      final completedDir = p.join(
        p.dirname(transactionDir),
        '.completed_${record['transactionId']}_${DateTime.now().microsecondsSinceEpoch}',
      );
      if (FileSystemEntity.typeSync(completedDir, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw _TemporaryHelperRepairConflict(
          'completed_tombstone_collision',
          <Map<String, Object?>>[
            <String, Object?>{'path': completedDir, 'actual': 'already_exists'},
          ],
        );
      }
      Directory(transactionDir).renameSync(completedDir);
      _temporaryHelperCheckpoint('cleanup_renamed');
      _deletePrivateDirectoryIfExists(completedDir, boundary: scoutRoot);
      _temporaryHelperCheckpoint('cleanup_deleted');
      return <String, Object?>{
        ...audit,
        'recordRemoved': true,
        'transactionDirectoryRemoved': true,
        'targetRemoved': targetResult['status'] != 'already_absent',
        'packageConfigRestored': true,
        'lockRestored': true,
      };
    } on _TemporaryHelperSimulatedInterruption {
      rethrow;
    } on _TemporaryHelperRepairConflict catch (error) {
      final project =
          record['projectPath']?.toString() ??
          _temporaryHelperProjectFromRecordPath(absoluteRecordPath);
      final action = _temporaryHelperPrioritizedAction(
        project,
        recordPath: absoluteRecordPath,
        reason: error.code,
      );
      try {
        _temporaryHelperSetPhase(record, 'repair_conflict');
        record['repair'] = <String, Object?>{
          'status': 'repair_required',
          'automatic': false,
          'priority': 'critical',
          'reason': error.code,
          'conflicts': error.conflicts,
          'prioritizedRecoveryAction': action,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        };
        _temporaryHelperWriteRecord(absoluteRecordPath, record);
      } catch (_) {
        // The original record remains the discovery anchor if even recording
        // conflict evidence is impossible (for example, a full disk).
      }
      return <String, Object?>{
        'status': 'repair_required',
        'reason': error.code,
        'recordPath': absoluteRecordPath,
        'conflicts': error.conflicts,
        'trackedInputsOverwritten': false,
        'prioritizedRecoveryAction': action,
      };
    } on ScoutCliException catch (error) {
      final project =
          record['projectPath']?.toString() ??
          _temporaryHelperProjectFromRecordPath(absoluteRecordPath);
      return _temporaryHelperBlockedReport(
        project: project,
        reason: error.code,
        message: error.message,
        recordPath: absoluteRecordPath,
      );
    } catch (error) {
      final project =
          record['projectPath']?.toString() ??
          _temporaryHelperProjectFromRecordPath(absoluteRecordPath);
      return _temporaryHelperBlockedReport(
        project: project,
        reason: 'repair_io_failure',
        message: _temporaryHelperBoundedText(error.toString()),
        recordPath: absoluteRecordPath,
      );
    }
  }

  Future<bool> _temporaryHelperRecordIsLive(Map<String, Object?> record) async {
    final ownerPid = (record['ownerProcessId'] as num?)?.toInt();
    final expectedOwner = record['ownerProcessIdentity'];
    if (ownerPid != null && expectedOwner is Map) {
      final current = await _readProcessOwnershipIdentity(
        ownerPid,
        role: _temporaryHelperOwnerRole,
      );
      if (current != null &&
          _sameProcessOwnershipIdentity(
            Map<Object?, Object?>.from(expectedOwner),
            current,
          )) {
        return true;
      }
    }
    final sessionDirectory = record['sessionDirectory']?.toString();
    if (sessionDirectory == null ||
        !_temporaryHelperValidAbsolutePath(sessionDirectory)) {
      return false;
    }
    final metaPath = p.join(sessionDirectory, 'session_meta.json');
    if (ownerPid != null && expectedOwner is! Map) {
      final launchPath = p.join(sessionDirectory, 'launch.lock');
      if (FileSystemEntity.typeSync(launchPath, followLinks: false) ==
          FileSystemEntityType.file) {
        try {
          final launch = jsonDecode(File(launchPath).readAsStringSync());
          if (launch is Map &&
              launch['runId'] == record['runId'] &&
              int.tryParse('${launch['ownerPid'] ?? ''}') == ownerPid &&
              await _processExists(ownerPid)) {
            // Platforms without immutable process-start facts fail safe by
            // preserving a transaction whose private launch lease and live
            // PID both match. They never auto-overwrite on uncertainty.
            return true;
          }
        } catch (_) {}
      }
    }
    if (FileSystemEntity.typeSync(metaPath, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    try {
      final decoded = jsonDecode(File(metaPath).readAsStringSync());
      if (decoded is! Map || decoded['runId'] != record['runId']) return false;
      if (decoded['state'] != 'ready' && decoded['state'] != 'building') {
        return false;
      }
      final temporarySetup = decoded['temporarySetup'];
      final recordPath = record['recordPath']?.toString();
      final ownsTemporarySetup =
          temporarySetup is Map &&
          recordPath != null &&
          temporarySetup['transactionRecordPath']?.toString() == recordPath;
      final supervisor = decoded['supervisor'];
      if (ownsTemporarySetup && supervisor is Map) {
        final supervisorRunId = supervisor['runId']?.toString();
        final configFile = supervisor['configFile']?.toString();
        final initialWorkerPid = int.tryParse(
          '${supervisor['workerPid'] ?? ''}',
        );
        final supervisorType = supervisor['type']?.toString();
        int? liveWorkerPid = supervisorType == 'detached_process'
            ? initialWorkerPid
            : null;
        if (supervisorType == 'launchd') {
          final domain = supervisor['domain']?.toString();
          final label = supervisor['label']?.toString();
          if (domain != null && label != null) {
            liveWorkerPid = await _launchdServicePid(
              domain: domain,
              label: label,
            );
          }
        }
        if (liveWorkerPid != null && supervisorRunId == record['runId']) {
          final state = _readSessionConfiguredJson('supervisorStateFile');
          final expectedIdentity = _selectRunnerWorkerIdentity(
            initialIdentity: supervisor['processIdentity'],
            expectedRunId: supervisorRunId,
            liveWorkerPid: liveWorkerPid,
            supervisorState: state,
          );
          if (await _matchesRunnerWorker(
            liveWorkerPid,
            expectedIdentity: expectedIdentity,
            expectedRunId: supervisorRunId,
            expectedConfigFile: configFile,
          )) {
            return true;
          }
        }
      }
      final processId = (decoded['pid'] as num?)?.toInt();
      final expected = decoded['processIdentity'];
      if (processId == null) return false;
      if (expected is! Map) {
        return ownsTemporarySetup && await _processExists(processId);
      }
      final current = await _readProcessOwnershipIdentity(
        processId,
        role: _flutterRunProcessRole,
      );
      return current != null &&
          _sameProcessOwnershipIdentity(
            Map<Object?, Object?>.from(expected),
            current,
          );
    } catch (_) {
      return false;
    }
  }
}
