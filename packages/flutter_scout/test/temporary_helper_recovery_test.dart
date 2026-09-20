import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  setUp(() {
    FlutterScoutCli.debugTemporaryHelperInterruptAfterPhase = null;
    FlutterScoutCli.debugTemporaryHelperPubGetOverride = _successfulFakePubGet;
  });

  tearDown(() {
    FlutterScoutCli.debugTemporaryHelperInterruptAfterPhase = null;
    FlutterScoutCli.debugTemporaryHelperPubGetOverride = null;
  });

  test(
    'WAL precedes mutation and normal cleanup is exact and idempotent',
    () async {
      final fixture = await _TemporaryProject.create(lockExists: true);
      addTearDown(fixture.dispose);
      final cli = FlutterScoutCli();

      final setup = await cli.debugPrepareTemporaryHelper(
        project: fixture.project.path,
        helperPath: fixture.helper.path,
      );

      expect(fixture.pubspec.readAsBytesSync(), fixture.originalPubspec);
      expect(fixture.lock.readAsBytesSync(), fixture.originalLock);
      expect(File(setup['targetPath']! as String).existsSync(), isTrue);
      final record = File(setup['transactionRecordPath']! as String);
      expect(record.existsSync(), isTrue);
      final decoded = jsonDecode(record.readAsStringSync()) as Map;
      expect(decoded['phase'], 'active');
      expect(
        decoded['recordIntegritySha256'],
        matches(RegExp(r'^[a-f0-9]{64}$')),
      );
      expect(decoded['restorePlan'], hasLength(5));
      for (final key in const <String>[
        'projectPath',
        'helperPath',
        'originalTargetPath',
        'generatedTargetPath',
        'pubspecPath',
        'lockPath',
      ]) {
        expect(p.isAbsolute(decoded[key] as String), isTrue, reason: key);
      }
      if (!Platform.isWindows) {
        expect(FileStat.statSync(record.path).mode & 0x1ff, 0x180);
        expect(FileStat.statSync(record.parent.path).mode & 0x1ff, 0x1c0);
      }

      final cleanup = await cli.debugCleanupTemporaryHelper(setup);
      expect(cleanup['status'], 'repaired');
      expect(cleanup['packageConfigRestored'], isTrue);
      expect(fixture.pubspec.readAsBytesSync(), fixture.originalPubspec);
      expect(fixture.lock.readAsBytesSync(), fixture.originalLock);
      expect(File(setup['targetPath']! as String).existsSync(), isFalse);
      expect(record.existsSync(), isFalse);
      expect(fixture.packageConfig.readAsStringSync(), contains('original'));

      final repeated = await cli.debugCleanupTemporaryHelper(setup);
      expect(repeated, containsPair('alreadyClean', true));
    },
  );

  test(
    'stale existing helper is replaced by the exact bundled helper without product drift',
    () async {
      final fixture = await _TemporaryProject.create(
        lockExists: true,
        existingHelperPath: '/tmp/stale-flutter-scout-helper',
      );
      addTearDown(fixture.dispose);
      final cli = FlutterScoutCli();
      final bundledHelper = await cli.debugDiscoverBundledHelperPath();
      expect(bundledHelper, isNotNull);
      String? resolvedDuringPubGet;
      FlutterScoutCli.debugTemporaryHelperPubGetOverride = (project) async {
        final pubspec = File(
          p.join(project, 'pubspec.yaml'),
        ).readAsStringSync();
        final candidateActive = pubspec.contains(
          "path: '${bundledHelper!.replaceAll("'", "''")}'",
        );
        if (candidateActive) {
          expect(pubspec, isNot(contains('/tmp/stale-flutter-scout-helper')));
          resolvedDuringPubGet = bundledHelper;
          _writePackageConfig(project, bundledHelper);
        } else {
          expect(pubspec, contains('/tmp/stale-flutter-scout-helper'));
          _writePackageConfig(project, fixture.helper.path);
        }
        File(p.join(project, 'pubspec.lock')).writeAsStringSync(
          candidateActive
              ? 'packages:\n  flutter_scout_helper: exact-bundled-helper\n'
              : 'packages:\n  flutter_scout_helper: stale\n',
          flush: true,
        );
        return ProcessResult(42, 0, 'resolved', '');
      };

      final setup = await cli.debugPrepareTemporaryHelper(
        project: fixture.project.path,
        helperPath: bundledHelper!,
        requireBundledHelper: true,
      );

      expect(resolvedDuringPubGet, bundledHelper);
      expect(fixture.pubspec.readAsBytesSync(), fixture.originalPubspec);
      expect(fixture.lock.readAsBytesSync(), fixture.originalLock);
      expect(
        _resolvedHelperFromPackageConfig(fixture.project.path),
        Directory(bundledHelper).resolveSymbolicLinksSync(),
      );
      await cli.debugCleanupTemporaryHelper(setup);
      expect(fixture.pubspec.readAsBytesSync(), fixture.originalPubspec);
      expect(fixture.lock.readAsBytesSync(), fixture.originalLock);
    },
  );

  test('resolved stale helper fails closed before launch', () async {
    final fixture = await _TemporaryProject.create(
      lockExists: true,
      existingHelperPath: '/tmp/stale-flutter-scout-helper',
    );
    addTearDown(fixture.dispose);
    final cli = FlutterScoutCli();
    final bundledHelper = await cli.debugDiscoverBundledHelperPath();
    expect(bundledHelper, isNotNull);
    FlutterScoutCli.debugTemporaryHelperPubGetOverride = (project) async {
      _writePackageConfig(project, fixture.helper.path);
      File(p.join(project, 'pubspec.lock')).writeAsStringSync(
        'packages:\n  flutter_scout_helper: stale\n',
        flush: true,
      );
      return ProcessResult(42, 0, 'resolved', '');
    };

    await expectLater(
      cli.debugPrepareTemporaryHelper(
        project: fixture.project.path,
        helperPath: bundledHelper!,
        requireBundledHelper: true,
      ),
      throwsA(
        isA<ScoutCliException>().having(
          (error) => error.code,
          'code',
          'temporary_helper_resolution_mismatch',
        ),
      ),
    );
    _expectTrackedInputsExact(fixture);
    expect(
      File(
        p.join(fixture.project.path, '.flutter_scout', 'bootstrap_test.dart'),
      ).existsSync(),
      isFalse,
    );
  });

  test(
    'explicit helper from another revision is rejected before mutation',
    () async {
      final fixture = await _TemporaryProject.create(lockExists: true);
      addTearDown(fixture.dispose);
      final originalPackageConfig = fixture.packageConfig.existsSync()
          ? fixture.packageConfig.readAsBytesSync()
          : null;

      await expectLater(
        FlutterScoutCli().debugPrepareTemporaryHelper(
          project: fixture.project.path,
          helperPath: fixture.helper.path,
          requireBundledHelper: true,
        ),
        throwsA(
          isA<ScoutCliException>().having(
            (error) => error.code,
            'code',
            'temporary_helper_revision_mismatch',
          ),
        ),
      );
      _expectTrackedInputsExact(fixture);
      expect(
        fixture.packageConfig.existsSync()
            ? fixture.packageConfig.readAsBytesSync()
            : null,
        originalPackageConfig,
      );
    },
  );

  for (final phase in const <String>[
    'record_prepared',
    'pubspec_write_started',
    'pubspec_injected',
    'helper_pub_get_started',
    'helper_pub_get_completed',
    'target_write_started',
    'target_written',
    'pubspec_restored',
    'lock_restored',
    'active',
  ]) {
    test('startup repairs interruption after $phase', () async {
      final fixture = await _TemporaryProject.create(lockExists: true);
      addTearDown(fixture.dispose);
      final cli = FlutterScoutCli();
      FlutterScoutCli.debugTemporaryHelperInterruptAfterPhase = phase;

      await expectLater(
        cli.debugPrepareTemporaryHelper(
          project: fixture.project.path,
          helperPath: fixture.helper.path,
        ),
        throwsA(anything),
      );
      FlutterScoutCli.debugTemporaryHelperInterruptAfterPhase = null;

      final repair = await cli.debugRecoverTemporaryHelperProject(
        fixture.project.path,
      );
      expect(repair['status'], 'repaired', reason: '$phase: $repair');
      _expectTrackedInputsExact(fixture);
      expect(
        File(
          p.join(fixture.project.path, '.flutter_scout', 'bootstrap_test.dart'),
        ).existsSync(),
        isFalse,
      );
    });
  }

  for (final phase in const <String>[
    'repair_started',
    'repair_pubspec_restored',
    'repair_lock_restored_before_pub_get',
    'repair_target_removed',
    'repair_pub_get_started',
    'repair_pub_get_completed',
    'repair_final_lock_restored',
    'cleanup_committing',
    'cleanup_renamed',
    'cleanup_deleted',
  ]) {
    test('cleanup resumes idempotently after $phase', () async {
      final fixture = await _TemporaryProject.create(lockExists: false);
      addTearDown(fixture.dispose);
      final cli = FlutterScoutCli();
      final setup = await cli.debugPrepareTemporaryHelper(
        project: fixture.project.path,
        helperPath: fixture.helper.path,
      );
      FlutterScoutCli.debugTemporaryHelperInterruptAfterPhase = phase;

      await expectLater(
        cli.debugCleanupTemporaryHelper(setup),
        throwsA(anything),
      );
      FlutterScoutCli.debugTemporaryHelperInterruptAfterPhase = null;
      final repair = await cli.debugRecoverTemporaryHelperProject(
        fixture.project.path,
      );

      expect(
        <Object?>['repaired', 'clean'],
        contains(repair['status']),
        reason: '$phase: $repair',
      );
      _expectTrackedInputsExact(fixture);
      expect(fixture.lock.existsSync(), isFalse);
      expect(File(setup['targetPath']! as String).existsSync(), isFalse);
    });
  }

  test('changed pubspec fails closed and preserves the user version', () async {
    final fixture = await _TemporaryProject.create(lockExists: true);
    addTearDown(fixture.dispose);
    final cli = FlutterScoutCli();
    final setup = await cli.debugPrepareTemporaryHelper(
      project: fixture.project.path,
      helperPath: fixture.helper.path,
    );
    const userVersion = 'name: user_changed_project\ndependencies: {}\n';
    fixture.pubspec.writeAsStringSync(userVersion, flush: true);

    final repair = await cli.debugRecoverTemporaryHelperProject(
      fixture.project.path,
    );

    expect(repair['status'], 'repair_required');
    expect(fixture.pubspec.readAsStringSync(), userVersion);
    expect(
      File(setup['transactionRecordPath']! as String).existsSync(),
      isTrue,
    );
    expect(repair.toString(), contains('preserved_without_overwrite'));
  });

  test('changed lock fails closed and preserves the user version', () async {
    final fixture = await _TemporaryProject.create(lockExists: true);
    addTearDown(fixture.dispose);
    final cli = FlutterScoutCli();
    final setup = await cli.debugPrepareTemporaryHelper(
      project: fixture.project.path,
      helperPath: fixture.helper.path,
    );
    const userLock = 'packages:\n  user_change: true\n';
    fixture.lock.writeAsStringSync(userLock, flush: true);

    final repair = await cli.debugRecoverTemporaryHelperProject(
      fixture.project.path,
    );

    expect(repair['status'], 'repair_required');
    expect(fixture.lock.readAsStringSync(), userLock);
    expect(
      File(setup['transactionRecordPath']! as String).existsSync(),
      isTrue,
    );
    expect(repair.toString(), contains('lock_changed_since_transaction'));
  });

  test('project .flutter_scout symbolic link is refused', () async {
    if (Platform.isWindows) return;
    final fixture = await _TemporaryProject.create(lockExists: true);
    addTearDown(fixture.dispose);
    final outside = await Directory.systemTemp.createTemp('scout_link_target_');
    addTearDown(() => outside.delete(recursive: true));
    await Link(
      p.join(fixture.project.path, '.flutter_scout'),
    ).create(outside.path);

    await expectLater(
      FlutterScoutCli().debugPrepareTemporaryHelper(
        project: fixture.project.path,
        helperPath: fixture.helper.path,
      ),
      throwsA(
        isA<ScoutCliException>().having(
          (error) => error.code,
          'code',
          'temporary_helper_scout_root_unsafe',
        ),
      ),
    );
    expect(outside.listSync(), isEmpty);
  });

  test('missing and corrupt repair records remain discoverable', () async {
    for (final corrupt in <bool>[false, true]) {
      final fixture = await _TemporaryProject.create(lockExists: true);
      addTearDown(fixture.dispose);
      final transaction = Directory(
        p.join(
          fixture.project.path,
          '.flutter_scout',
          'temporary_helper',
          'transactions',
          corrupt ? 'corrupt' : 'missing',
        ),
      )..createSync(recursive: true);
      if (corrupt) {
        File(p.join(transaction.path, 'repair.json')).writeAsStringSync('{');
      }

      final repair = await FlutterScoutCli().debugRecoverTemporaryHelperProject(
        fixture.project.path,
      );

      expect(repair['status'], 'repair_required');
      expect(
        repair.toString(),
        contains(corrupt ? 'record_corrupt' : 'record_missing'),
      );
      _expectTrackedInputsExact(fixture);
      expect(transaction.existsSync(), isTrue);
    }
  });

  test(
    'pub-get failure restores tracked inputs and retains repair evidence',
    () async {
      final fixture = await _TemporaryProject.create(lockExists: true);
      addTearDown(fixture.dispose);
      FlutterScoutCli.debugTemporaryHelperPubGetOverride = (project) async {
        File(p.join(project, 'pubspec.lock')).writeAsStringSync(
          'packages:\n  partial_tool_output: true\n',
          flush: true,
        );
        return ProcessResult(99, 1, '', 'injected pub-get failure');
      };

      await expectLater(
        FlutterScoutCli().debugPrepareTemporaryHelper(
          project: fixture.project.path,
          helperPath: fixture.helper.path,
        ),
        throwsA(
          isA<ScoutCliException>().having(
            (error) => error.code,
            'code',
            'temporary_helper_repair_required',
          ),
        ),
      );

      _expectTrackedInputsExact(fixture);
      final records = Directory(
        p.join(
          fixture.project.path,
          '.flutter_scout',
          'temporary_helper',
          'transactions',
        ),
      ).listSync(recursive: true, followLinks: false);
      expect(
        records.whereType<File>().map((file) => p.basename(file.path)),
        contains('repair.json'),
      );
    },
  );

  test(
    'startup preserves a helper owned by a live detached build worker',
    () async {
      if (Platform.isWindows) return;
      final fixture = await _TemporaryProject.create(lockExists: false);
      addTearDown(fixture.dispose);
      final projectPath = fixture.project.resolveSymbolicLinksSync();
      final packageRoot = Directory.current.absolute.path;
      final ownerFixture = p.join(
        packageRoot,
        'test',
        'fixtures',
        'temporary_helper_owner.dart',
      );
      final owner = await Process.run(Platform.resolvedExecutable, [
        ownerFixture,
        projectPath,
        fixture.helper.path,
      ], workingDirectory: packageRoot);
      expect(owner.exitCode, 0, reason: '${owner.stderr}');

      final scoutRoot = p.join(projectPath, '.flutter_scout');
      const runId = 'test';
      final recordPath = p.join(
        scoutRoot,
        'temporary_helper',
        'transactions',
        runId,
        'repair.json',
      );
      final targetPath = p.join(scoutRoot, 'bootstrap_$runId.dart');
      final workerScript = File(p.join(scoutRoot, 'flutter_scout_worker.dart'))
        ..writeAsStringSync('''
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  stdout.writeln('worker-ready');
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
      final config = File(p.join(scoutRoot, 'runs', runId, 'worker.json'));
      config.parent.createSync(recursive: true);
      config.writeAsStringSync('{}');
      final worker = await Process.start(Platform.resolvedExecutable, [
        // The temporary app deliberately has a fake package_config. Use this
        // test package's real config so the worker survives compilation.
        '--packages=${p.join(packageRoot, '.dart_tool', 'package_config.json')}',
        workerScript.path,
        'flutter-run-worker',
        '--config',
        config.path,
      ]);
      addTearDown(() async {
        if (await _processIsAlive(worker.pid)) {
          worker.kill(ProcessSignal.sigterm);
          await worker.exitCode.timeout(const Duration(seconds: 2));
        }
      });
      // A PID can exist while the Dart launcher is still replacing itself.
      // Capture ownership only after the actual fixture worker is running.
      expect(
        await worker.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 15)),
        'worker-ready',
      );
      expect(await _processIsAlive(worker.pid), isTrue);
      final identity = await _processIdentity(
        worker.pid,
        commandIdentity: 'flutter_run_worker',
      );
      File(p.join(scoutRoot, 'session_meta.json')).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'mode': 'scout_owned_flutter_run',
          'state': 'building',
          'runId': runId,
          'project': projectPath,
          'temporarySetup': <String, Object?>{
            'transactionRecordPath': recordPath,
          },
          'supervisor': <String, Object?>{
            'type': 'detached_process',
            'workerPid': worker.pid,
            'runId': runId,
            'configFile': config.path,
            'processIdentity': identity,
          },
        }),
      );
      final active = await FlutterScoutCli().debugWithLaunchLease(
        sessionDirectory: scoutRoot,
        project: projectPath,
        device: 'test-device',
        body: (_) {
          return FlutterScoutCli().debugRecoverTemporaryHelperProject(
            projectPath,
            preserveLive: true,
          );
        },
      );
      expect(active['status'], 'active', reason: '$active');
      expect(File(targetPath).existsSync(), isTrue);
      expect(File(recordPath).existsSync(), isTrue);

      worker.kill(ProcessSignal.sigterm);
      await worker.exitCode.timeout(const Duration(seconds: 2));
      final repaired = await FlutterScoutCli().debugWithLaunchLease(
        sessionDirectory: scoutRoot,
        project: projectPath,
        device: 'test-device',
        body: (_) => FlutterScoutCli().debugRecoverTemporaryHelperProject(
          projectPath,
          preserveLive: true,
        ),
      );
      expect(repaired['status'], 'repaired', reason: '$repaired');
      expect(File(targetPath).existsSync(), isFalse);
    },
  );

  test(
    'workspace override resolves one helper and cleanup restores every artifact',
    () async {
      final fixture = await _WorkspaceTemporaryProject.create();
      addTearDown(fixture.dispose);
      final cli = FlutterScoutCli();
      FlutterScoutCli.debugTemporaryHelperPubGetOverride =
          (workingDirectory) async {
            expect(workingDirectory, fixture.root.resolveSymbolicLinksSync());
            fixture.expectCandidateOverride();
            fixture.writeCandidateArtifacts();
            return ProcessResult(42, 0, 'resolved workspace', '');
          };

      final setup = await cli.debugPrepareTemporaryHelper(
        project: fixture.selected.path,
        helperPath: fixture.helper.path,
      );

      fixture.expectTrackedInputsExact();
      fixture.expectCandidateResolution();
      final record =
          jsonDecode(
                File(
                  setup['transactionRecordPath']! as String,
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(
        record['resolutionRootPath'],
        fixture.root.resolveSymbolicLinksSync(),
      );
      expect(record['workspaceMemberPaths'], hasLength(2));
      expect(record['generatedArtifacts'], hasLength(11));

      final cleanup = await cli.debugCleanupTemporaryHelper(setup);
      expect(cleanup['status'], 'repaired');
      fixture.expectAllArtifactsExact();
    },
  );

  test(
    'workspace setup failure restores generated and tracked artifacts',
    () async {
      final fixture = await _WorkspaceTemporaryProject.create();
      addTearDown(fixture.dispose);
      FlutterScoutCli.debugTemporaryHelperPubGetOverride =
          (workingDirectory) async {
            expect(workingDirectory, fixture.root.resolveSymbolicLinksSync());
            fixture.expectCandidateOverride();
            fixture.writeCandidateArtifacts();
            return ProcessResult(42, 1, '', 'workspace resolution failed');
          };

      await expectLater(
        FlutterScoutCli().debugPrepareTemporaryHelper(
          project: fixture.selected.path,
          helperPath: fixture.helper.path,
        ),
        throwsA(isA<ScoutCliException>()),
      );

      fixture.expectAllArtifactsExact();
    },
  );

  for (final phase in const <String>[
    'record_prepared',
    'workspace_override_write_started',
    'workspace_override_injected',
    'helper_pub_get_started',
    'helper_pub_get_completed',
    'target_write_started',
    'target_written',
    'workspace_override_restored',
    'lock_restored',
    'active',
  ]) {
    test(
      'workspace interruption after $phase restores every artifact',
      () async {
        final fixture = await _WorkspaceTemporaryProject.create();
        addTearDown(fixture.dispose);
        final cli = FlutterScoutCli();
        FlutterScoutCli.debugTemporaryHelperPubGetOverride =
            (workingDirectory) async {
              fixture.expectCandidateOverride();
              fixture.writeCandidateArtifacts();
              return ProcessResult(42, 0, 'resolved workspace', '');
            };
        FlutterScoutCli.debugTemporaryHelperInterruptAfterPhase = phase;

        await expectLater(
          cli.debugPrepareTemporaryHelper(
            project: fixture.selected.path,
            helperPath: fixture.helper.path,
          ),
          throwsA(anything),
        );
        FlutterScoutCli.debugTemporaryHelperInterruptAfterPhase = null;
        final recovery = await cli.debugRecoverTemporaryHelperProject(
          fixture.selected.path,
        );

        expect(recovery['status'], 'repaired', reason: '$phase: $recovery');
        fixture.expectAllArtifactsExact();
      },
    );
  }

  test(
    'workspace recovery resumes after interrupted candidate resolution',
    () async {
      final fixture = await _WorkspaceTemporaryProject.create();
      addTearDown(fixture.dispose);
      final cli = FlutterScoutCli();
      FlutterScoutCli.debugTemporaryHelperPubGetOverride =
          (workingDirectory) async {
            fixture.expectCandidateOverride();
            fixture.writeCandidateArtifacts();
            return ProcessResult(42, 0, 'resolved workspace', '');
          };
      FlutterScoutCli.debugTemporaryHelperInterruptAfterPhase =
          'helper_pub_get_started';
      await expectLater(
        cli.debugPrepareTemporaryHelper(
          project: fixture.selected.path,
          helperPath: fixture.helper.path,
        ),
        throwsA(anything),
      );
      FlutterScoutCli.debugTemporaryHelperInterruptAfterPhase =
          'repair_candidate_resolution_completed';
      await expectLater(
        cli.debugRecoverTemporaryHelperProject(fixture.selected.path),
        throwsA(anything),
      );
      FlutterScoutCli.debugTemporaryHelperInterruptAfterPhase = null;

      final recovery = await cli.debugRecoverTemporaryHelperProject(
        fixture.selected.path,
      );
      expect(recovery['status'], 'repaired', reason: '$recovery');
      fixture.expectAllArtifactsExact();
    },
  );

  for (final phase in const <String>[
    'repair_workspace_artifacts_restored',
    'repair_target_removed',
    'cleanup_committing',
    'cleanup_renamed',
    'cleanup_deleted',
  ]) {
    test('workspace cleanup resumes after $phase', () async {
      final fixture = await _WorkspaceTemporaryProject.create();
      addTearDown(fixture.dispose);
      final cli = FlutterScoutCli();
      FlutterScoutCli.debugTemporaryHelperPubGetOverride =
          (workingDirectory) async {
            fixture.expectCandidateOverride();
            fixture.writeCandidateArtifacts();
            return ProcessResult(42, 0, 'resolved workspace', '');
          };
      final setup = await cli.debugPrepareTemporaryHelper(
        project: fixture.selected.path,
        helperPath: fixture.helper.path,
      );
      FlutterScoutCli.debugTemporaryHelperInterruptAfterPhase = phase;
      await expectLater(
        cli.debugCleanupTemporaryHelper(setup),
        throwsA(anything),
      );
      FlutterScoutCli.debugTemporaryHelperInterruptAfterPhase = null;

      final recovery = await cli.debugRecoverTemporaryHelperProject(
        fixture.selected.path,
      );
      expect(
        <Object?>['repaired', 'clean'],
        contains(recovery['status']),
        reason: '$phase: $recovery',
      );
      fixture.expectAllArtifactsExact();
    });
  }

  test(
    'workspace member escaping the root is refused before mutation',
    () async {
      if (Platform.isWindows) return;
      final fixture = await _WorkspaceTemporaryProject.create(
        escapingMember: true,
      );
      addTearDown(fixture.dispose);

      await expectLater(
        FlutterScoutCli().debugPrepareTemporaryHelper(
          project: fixture.selected.path,
          helperPath: fixture.helper.path,
        ),
        throwsA(
          isA<ScoutCliException>().having(
            (error) => error.code,
            'code',
            'temporary_helper_workspace_member_unsafe',
          ),
        ),
      );
      fixture.expectAllArtifactsExact();
    },
  );
}

Future<Map<String, Object?>> _processIdentity(
  int pid, {
  required String commandIdentity,
}) async {
  Future<String> field(String name) async {
    final result = await Process.run('ps', ['-p', '$pid', '-o', '$name=']);
    expect(result.exitCode, 0);
    return '${result.stdout}'.trim();
  }

  return <String, Object?>{
    'pid': pid,
    'parentPid': int.parse(await field('ppid')),
    'startedAt': await field('lstart'),
    'executable': await field('comm'),
    'commandIdentity': commandIdentity,
  };
}

Future<bool> _processIsAlive(int pid) async {
  final result = await Process.run('ps', ['-p', '$pid', '-o', 'pid=']);
  return result.exitCode == 0 && '${result.stdout}'.trim().isNotEmpty;
}

Future<ProcessResult> _successfulFakePubGet(String project) async {
  final pubspec = File(p.join(project, 'pubspec.yaml')).readAsStringSync();
  final helperMatch = RegExp(
    r"flutter_scout_helper:\s*\n\s+path:\s*'([^']+)'",
  ).firstMatch(pubspec);
  final helperActive = helperMatch != null;
  final config = File(p.join(project, '.dart_tool', 'package_config.json'));
  config.parent.createSync(recursive: true);
  if (helperMatch != null) {
    _writePackageConfig(project, helperMatch.group(1)!);
  } else {
    config.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'configVersion': 2,
        'mode': 'original',
        'packages': const <Object?>[],
      }),
      flush: true,
    );
  }
  File(p.join(project, 'pubspec.lock')).writeAsStringSync(
    helperActive
        ? 'packages:\n  flutter_scout_helper: tool\n'
        : 'packages:\n  cleanup_output: tool\n',
    flush: true,
  );
  return ProcessResult(42, 0, 'resolved', '');
}

void _writePackageConfig(String project, String helperPath) {
  final config = File(p.join(project, '.dart_tool', 'package_config.json'));
  config.parent.createSync(recursive: true);
  config.writeAsStringSync(
    jsonEncode(<String, Object?>{
      'configVersion': 2,
      'packages': <Object?>[
        <String, Object?>{
          'name': 'flutter_scout_helper',
          'rootUri': Uri.directory(helperPath).toString(),
          'packageUri': 'lib/',
          'languageVersion': '3.12',
        },
      ],
    }),
    flush: true,
  );
}

String? _resolvedHelperFromPackageConfig(String project) {
  final config = File(p.join(project, '.dart_tool', 'package_config.json'));
  final decoded = jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
  final packages = decoded['packages']! as List<Object?>;
  final helper = packages.cast<Map<String, Object?>>().singleWhere(
    (entry) => entry['name'] == 'flutter_scout_helper',
  );
  return Directory.fromUri(
    config.uri.resolve(helper['rootUri']! as String),
  ).resolveSymbolicLinksSync();
}

void _expectTrackedInputsExact(_TemporaryProject fixture) {
  expect(fixture.pubspec.readAsBytesSync(), fixture.originalPubspec);
  if (fixture.originalLock == null) {
    expect(fixture.lock.existsSync(), isFalse);
  } else {
    expect(fixture.lock.readAsBytesSync(), fixture.originalLock);
  }
}

final class _TemporaryProject {
  const _TemporaryProject({
    required this.root,
    required this.project,
    required this.helper,
    required this.pubspec,
    required this.lock,
    required this.packageConfig,
    required this.originalPubspec,
    required this.originalLock,
  });

  final Directory root;
  final Directory project;
  final Directory helper;
  final File pubspec;
  final File lock;
  final File packageConfig;
  final List<int> originalPubspec;
  final List<int>? originalLock;

  static Future<_TemporaryProject> create({
    required bool lockExists,
    String? existingHelperPath,
  }) async {
    final root = await Directory.systemTemp.createTemp('scout_wal_test_');
    final project = Directory(p.join(root.path, 'app'))..createSync();
    final helper = Directory(p.join(root.path, 'helper'))..createSync();
    File(p.join(helper.path, 'pubspec.yaml')).writeAsStringSync('''
name: flutter_scout_helper
environment:
  sdk: ^3.12.0
''');
    final pubspec = File(p.join(project.path, 'pubspec.yaml'))
      ..writeAsStringSync('''
name: temporary_scout_app
environment:
  sdk: ^3.12.0
dependencies:
  flutter:
    sdk: flutter
${existingHelperPath == null ? '' : "  flutter_scout_helper:\n    path: '$existingHelperPath'\n"}
''');
    final main = File(p.join(project.path, 'lib', 'main.dart'));
    main.parent.createSync(recursive: true);
    main.writeAsStringSync('void main() {}\n');
    final lock = File(p.join(project.path, 'pubspec.lock'));
    if (lockExists) {
      lock.writeAsStringSync('packages:\n  original: true\n');
    }
    return _TemporaryProject(
      root: root,
      project: project,
      helper: helper,
      pubspec: pubspec,
      lock: lock,
      packageConfig: File(
        p.join(project.path, '.dart_tool', 'package_config.json'),
      ),
      originalPubspec: pubspec.readAsBytesSync(),
      originalLock: lockExists ? lock.readAsBytesSync() : null,
    );
  }

  Future<void> dispose() async {
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

final class _WorkspaceTemporaryProject {
  const _WorkspaceTemporaryProject({
    required this.container,
    required this.root,
    required this.selected,
    required this.sibling,
    required this.helper,
    required this.originalArtifacts,
  });

  final Directory container;
  final Directory root;
  final Directory selected;
  final Directory sibling;
  final Directory helper;
  final Map<String, List<int>?> originalArtifacts;

  static const artifactNames = <String>[
    'pubspec_overrides.yaml',
    'pubspec.lock',
    '.dart_tool/package_config.json',
    '.dart_tool/package_graph.json',
    'apps/selected/.dart_tool/package_config_subset',
    'apps/selected/.flutter-plugins',
    'apps/selected/.flutter-plugins-dependencies',
    'apps/sibling/.flutter-plugins-dependencies',
  ];

  static Future<_WorkspaceTemporaryProject> create({
    bool escapingMember = false,
  }) async {
    final container = await Directory.systemTemp.createTemp(
      'scout_workspace_wal_test_',
    );
    final root = Directory(p.join(container.path, 'workspace'))..createSync();
    final selected = Directory(p.join(root.path, 'apps', 'selected'))
      ..createSync(recursive: true);
    final sibling = Directory(p.join(root.path, 'apps', 'sibling'))
      ..createSync(recursive: true);
    final helper = Directory(p.join(container.path, 'helper'))..createSync();
    File(p.join(helper.path, 'pubspec.yaml')).writeAsStringSync('''
name: flutter_scout_helper
environment:
  sdk: ^3.12.0
''');
    final workspaceEntry = escapingMember ? '../outside' : 'apps/sibling';
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: fixture_workspace
environment:
  sdk: ^3.12.0
workspace:
  - apps/selected
  - $workspaceEntry
''');
    for (final entry in <MapEntry<Directory, String>>[
      MapEntry(selected, '/tmp/selected-stale-helper'),
      MapEntry(sibling, '/tmp/sibling-stale-helper'),
    ]) {
      File(p.join(entry.key.path, 'pubspec.yaml')).writeAsStringSync('''
name: ${p.basename(entry.key.path)}
resolution: workspace
environment:
  sdk: ^3.12.0
dependencies:
  flutter_scout_helper:
    path: '${entry.value}'
''');
      final main = File(p.join(entry.key.path, 'lib', 'main.dart'));
      main.parent.createSync(recursive: true);
      main.writeAsStringSync('void main() {}\n');
    }
    if (escapingMember) {
      final outside = Directory(p.join(container.path, 'outside'))
        ..createSync();
      File(p.join(outside.path, 'pubspec.yaml')).writeAsStringSync('''
name: outside
resolution: workspace
environment:
  sdk: ^3.12.0
''');
    }
    final fixture = _WorkspaceTemporaryProject(
      container: container,
      root: root,
      selected: selected,
      sibling: sibling,
      helper: helper,
      originalArtifacts: <String, List<int>?>{},
    );
    for (final name in artifactNames) {
      final file = File(p.join(root.path, name));
      if (name == 'pubspec_overrides.yaml') {
        file.writeAsStringSync('''
dependency_overrides:
  existing_override:
    path: ../existing
''');
      } else if (name != 'apps/selected/.flutter-plugins') {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('original:$name\n');
      }
      fixture.originalArtifacts[name] = file.existsSync()
          ? file.readAsBytesSync()
          : null;
    }
    return fixture;
  }

  void expectCandidateOverride() {
    final override = File(
      p.join(root.path, 'pubspec_overrides.yaml'),
    ).readAsStringSync();
    expect(override, contains('existing_override:'));
    expect(override, contains('flutter_scout_helper:'));
    expect(override, contains(helper.resolveSymbolicLinksSync()));
  }

  void writeCandidateArtifacts() {
    for (final name in artifactNames.skip(1)) {
      final file = File(p.join(root.path, name));
      file.parent.createSync(recursive: true);
      if (name == '.dart_tool/package_config.json') {
        _writePackageConfig(root.path, helper.path);
      } else {
        file.writeAsStringSync('candidate:$name\n', flush: true);
      }
    }
  }

  void expectTrackedInputsExact() {
    for (final name in artifactNames.take(2)) {
      _expectArtifactExact(name);
    }
    expect(
      File(p.join(selected.path, 'pubspec.yaml')).readAsStringSync(),
      contains('/tmp/selected-stale-helper'),
    );
    expect(
      File(p.join(sibling.path, 'pubspec.yaml')).readAsStringSync(),
      contains('/tmp/sibling-stale-helper'),
    );
  }

  void expectCandidateResolution() {
    expect(
      _resolvedHelperFromPackageConfig(root.path),
      helper.resolveSymbolicLinksSync(),
    );
  }

  void expectAllArtifactsExact() {
    for (final name in artifactNames) {
      _expectArtifactExact(name);
    }
  }

  void _expectArtifactExact(String name) {
    final file = File(p.join(root.path, name));
    final original = originalArtifacts[name];
    if (original == null) {
      expect(file.existsSync(), isFalse, reason: name);
    } else {
      expect(file.readAsBytesSync(), original, reason: name);
    }
  }

  Future<void> dispose() async {
    if (container.existsSync()) await container.delete(recursive: true);
  }
}
