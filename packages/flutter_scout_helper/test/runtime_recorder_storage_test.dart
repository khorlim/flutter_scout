import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

bool get _supportsHelperPrivateStore =>
    Platform.isMacOS || (Platform.isLinux && !Platform.isAndroid);

String get _directDartExecutable {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final candidate = '$flutterRoot/bin/cache/dart-sdk/bin/dart';
    if (File(candidate).existsSync()) return candidate;
  }
  const cacheMarker = '/bin/cache/';
  final markerIndex = Platform.resolvedExecutable.indexOf(cacheMarker);
  if (markerIndex > 0) {
    final flutter = Platform.resolvedExecutable.substring(0, markerIndex);
    final candidate = '$flutter/bin/cache/dart-sdk/bin/dart';
    if (File(candidate).existsSync()) return candidate;
  }
  return 'dart';
}

Future<void> _terminateProcessBounded(Process process) async {
  try {
    await process.exitCode.timeout(const Duration(milliseconds: 50));
    return;
  } on TimeoutException {
    // Still live. Escalate through TERM then KILL, each with a hard bound.
  }
  process.kill(ProcessSignal.sigterm);
  try {
    await process.exitCode.timeout(const Duration(seconds: 1));
    return;
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
  }
  try {
    await process.exitCode.timeout(const Duration(seconds: 1));
  } on TimeoutException {
    // Never let test cleanup deadlock the whole suite. A killed process cannot
    // retain its advisory file lock once the OS reaps it.
  }
}

Future<Map<String, Object?>> _recordEmptyFlow(
  WidgetTester tester, {
  required String root,
  required String name,
  String feature = 'members',
}) async {
  FlutterScoutHelper.ensureRegistered();
  final runtime = FlutterScoutHelper.debugRuntime;
  if (runtime.debugIsRecording) {
    await runtime.debugStopRecording(discard: true);
  }
  runtime.debugSetRecordingsRootOverride(root);
  runtime.debugStartRecording(name: name, feature: feature);
  final result = await tester.runAsync(() => runtime.debugStopRecording());
  return result!;
}

void main() {
  testWidgets(
    'recorder writes atomic owner-only artifacts with explicit privacy metadata',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'scout_recorder_storage_',
      );
      addTearDown(() {
        FlutterScoutHelper.debugRuntime.debugSetRecordingsRootOverride(null);
        temp.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Recorder storage'))),
      );
      await tester.pump();

      final root = '${temp.path}/recordings';
      final result = await _recordEmptyFlow(
        tester,
        root: root,
        name: 'first-flow',
      );

      if (!_supportsHelperPrivateStore) {
        expect(result['persisted'], isFalse);
        expect(result['persistenceStatus'], 'delegated_to_cli');
        expect(
          result['persistenceReason'],
          'helper_private_storage_unsupported_platform',
        );
        expect(result['flow'], isA<Map>());
        return;
      }

      expect(result['persisted'], isTrue);
      expect(result['persistenceStatus'], 'persisted_by_helper');
      final flowFile = File('$root/members/first-flow.json');
      final indexFile = File('$root/index.json');
      final lockFile = File('$root/index.json.lock');
      expect(flowFile.existsSync(), isTrue);
      expect(indexFile.existsSync(), isTrue);
      expect(lockFile.existsSync(), isTrue);

      expect(FileStat.statSync(root).mode & 0x1ff, 0x1c0);
      expect(FileStat.statSync('$root/members').mode & 0x1ff, 0x1c0);
      expect(FileStat.statSync(flowFile.path).mode & 0x1ff, 0x180);
      expect(FileStat.statSync(indexFile.path).mode & 0x1ff, 0x180);
      expect(FileStat.statSync(lockFile.path).mode & 0x1ff, 0x180);

      final flow = jsonDecode(flowFile.readAsStringSync()) as Map;
      expect(flow['dataClassification'], 'private_application_data');
      expect(flow['containsPrivateApplicationData'], isTrue);
      expect(flow['telemetryCollected'], isFalse);
      expect((flow['retentionPolicy'] as Map)['policy'], 'manual');
      expect(
        (flow['retentionPolicy'] as Map)['disposition'],
        'explicit_manual_deletion',
      );

      final index = jsonDecode(indexFile.readAsStringSync()) as Map;
      expect(index['dataClassification'], 'private_application_data');
      expect(index['telemetryCollected'], isFalse);
      expect((index['recordings'] as List), hasLength(1));
      expect(
        Directory(root)
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .map((file) => file.path)
            .where((path) => path.endsWith('.tmp')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'recorder excludes corrupt flows and deterministically removes stale temps',
    (tester) async {
      if (!_supportsHelperPrivateStore) return;
      final temp = Directory.systemTemp.createTempSync(
        'scout_recorder_recovery_',
      );
      addTearDown(() {
        FlutterScoutHelper.debugRuntime.debugSetRecordingsRootOverride(null);
        temp.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Recorder recovery'))),
      );
      await tester.pump();

      final root = '${temp.path}/recordings';
      await _recordEmptyFlow(tester, root: root, name: 'first-flow');
      final corrupt = File('$root/members/corrupt.json')
        ..writeAsStringSync('{"steps": [');
      final legacy = File('$root/members/legacy.json')
        ..writeAsStringSync(
          jsonEncode({
            'schemaVersion': 1,
            'name': 'legacy',
            'feature': 'members',
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'steps': [
              {'cmd': 'input', 'target': 'field.note', 'value': 'private note'},
              {
                'cmd': 'fill',
                'values': jsonEncode({'field.email': 'private@example.test'}),
              },
            ],
          }),
        );
      final staleTemporary = File('$root/members/.stale.json.123.1.2.tmp')
        ..writeAsStringSync('partial');
      final staleIndexTemporary = File('$root/.index.json.123.1.2.tmp')
        ..writeAsStringSync('partial');
      staleTemporary.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 25)),
      );
      staleIndexTemporary.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 25)),
      );

      final result = await _recordEmptyFlow(
        tester,
        root: root,
        name: 'second-flow',
      );
      expect(result['persisted'], isTrue);
      expect(staleTemporary.existsSync(), isFalse);
      expect(staleIndexTemporary.existsSync(), isFalse);
      expect(corrupt.existsSync(), isTrue, reason: 'corrupt user data is kept');
      expect(FileStat.statSync(corrupt.path).mode & 0x1ff, 0x180);
      final repairedLegacy = legacy.readAsStringSync();
      expect(repairedLegacy, isNot(contains('private note')));
      expect(repairedLegacy, isNot(contains('private@example.test')));
      expect(repairedLegacy, contains(r'\u0000VAR:field.note'));
      expect(repairedLegacy, contains(r'\u0000VAR:field.email'));

      final index =
          jsonDecode(File('$root/index.json').readAsStringSync()) as Map;
      final rows = index['recordings'] as List;
      expect(
        rows.map((row) => row['name']),
        containsAll(['first-flow', 'legacy', 'second-flow']),
      );
      expect(rows.map((row) => row['name']), isNot(contains('corrupt')));
      final ignored = index['ignoredArtifacts'] as List;
      expect(
        ignored,
        contains(
          containsPair('reason', 'corrupt_or_incompatible_recording_excluded'),
        ),
      );
      expect(
        ignored,
        contains(containsPair('reason', 'stale_atomic_temporary_removed')),
      );
    },
  );

  testWidgets('recorder queues behind the cross-process index lock', (
    tester,
  ) async {
    if (!_supportsHelperPrivateStore) return;
    final temp = Directory.systemTemp.createTempSync('scout_recorder_lock_');
    Process? lockHolder;
    addTearDown(() async {
      FlutterScoutHelper.debugRuntime.debugSetRecordingsRootOverride(null);
      final process = lockHolder;
      if (process != null) {
        await _terminateProcessBounded(process);
      }
      temp.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Recorder lock safety'))),
    );
    await tester.pump();

    final root = '${temp.path}/recordings';
    await _recordEmptyFlow(tester, root: root, name: 'before-lock');
    final script = File('${temp.path}/hold_lock.dart')
      ..writeAsStringSync('''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final handle = File(arguments.single).openSync(mode: FileMode.append);
  handle.lockSync(FileLock.blockingExclusive);
  try {
    stdout.writeln('locked');
    await stdout.flush();
    // A synchronous OS sleep makes release independent of event-loop/timer
    // scheduling in either Flutter tester or the child Dart isolate.
    sleep(const Duration(milliseconds: 700));
  } finally {
    handle.unlockSync();
    handle.closeSync();
  }
}
''');
    final launched = await tester.runAsync(() async {
      final process = await Process.start(_directDartExecutable, [
        script.path,
        '$root/index.json.lock',
      ]);
      lockHolder = process;
      final stderr = process.stderr.transform(utf8.decoder).join();
      final ready = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 10));
      return (process: process, stderr: stderr, ready: ready);
    });
    lockHolder = launched!.process;
    expect(launched.ready, 'locked');

    final stopwatch = Stopwatch()..start();
    final result = await _recordEmptyFlow(
      tester,
      root: root,
      name: 'after-lock',
    );
    stopwatch.stop();
    final childResult = await tester.runAsync(() async {
      return (
        exitCode: await lockHolder!.exitCode.timeout(
          const Duration(seconds: 5),
        ),
        stderr: await launched.stderr.timeout(const Duration(seconds: 1)),
      );
    });
    expect(childResult!.exitCode, 0, reason: childResult.stderr);
    expect(result['persisted'], isTrue);
    expect(
      stopwatch.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 400)),
      reason: 'the helper must block instead of dropping a concurrent writer',
    );
  });

  testWidgets('recorder refuses symbolic-link targets and preserves fallback', (
    tester,
  ) async {
    if (!_supportsHelperPrivateStore) return;
    final temp = Directory.systemTemp.createTempSync('scout_recorder_link_');
    addTearDown(() {
      FlutterScoutHelper.debugRuntime.debugSetRecordingsRootOverride(null);
      temp.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Recorder link safety'))),
    );
    await tester.pump();

    final root = '${temp.path}/recordings';
    await _recordEmptyFlow(tester, root: root, name: 'protected-flow');
    final target = File('$root/members/protected-flow.json')..deleteSync();
    final victim = File('${temp.path}/victim.json')
      ..writeAsStringSync('do not overwrite');
    Link(target.path).createSync(victim.path);

    final result = await _recordEmptyFlow(
      tester,
      root: root,
      name: 'protected-flow',
    );
    expect(result['persisted'], isFalse);
    expect(result['persistenceStatus'], 'delegated_to_cli');
    expect(result['persistenceReason'], 'recording_symbolic_link_refused');
    expect(result['flow'], isA<Map>());
    expect(victim.readAsStringSync(), 'do not overwrite');
  });

  testWidgets(
    'recorder rejects lexical path traversal and preserves fallback',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('scout_recorder_path_');
      addTearDown(() {
        FlutterScoutHelper.debugRuntime.debugSetRecordingsRootOverride(null);
        temp.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Recorder path safety'))),
      );
      await tester.pump();

      final result = await _recordEmptyFlow(
        tester,
        root: '${temp.path}/safe/../escaped',
        name: 'path-flow',
      );
      expect(result['persisted'], isFalse);
      expect(result['persistenceStatus'], 'delegated_to_cli');
      expect(result['persistenceReason'], 'unsafe_recording_root');
      expect(result['flow'], isA<Map>());
      expect(Directory('${temp.path}/escaped').existsSync(), isFalse);
    },
  );
}
