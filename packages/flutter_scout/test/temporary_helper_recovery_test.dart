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
}

Future<ProcessResult> _successfulFakePubGet(String project) async {
  final pubspec = File(p.join(project, 'pubspec.yaml')).readAsStringSync();
  final helperActive = pubspec.contains('flutter_scout_helper:');
  final config = File(p.join(project, '.dart_tool', 'package_config.json'));
  config.parent.createSync(recursive: true);
  config.writeAsStringSync(
    jsonEncode(<String, Object?>{
      'configVersion': 2,
      'mode': helperActive ? 'helper' : 'original',
    }),
    flush: true,
  );
  File(p.join(project, 'pubspec.lock')).writeAsStringSync(
    helperActive
        ? 'packages:\n  flutter_scout_helper: tool\n'
        : 'packages:\n  cleanup_output: tool\n',
    flush: true,
  );
  return ProcessResult(42, 0, 'resolved', '');
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

  static Future<_TemporaryProject> create({required bool lockExists}) async {
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
