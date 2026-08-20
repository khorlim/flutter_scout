import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<Map<String, Object?>> processIdentity(
  int pid, {
  String commandIdentity = 'flutter_run',
}) async {
  Future<String> field(String name) async {
    final result = await Process.run('ps', ['-p', '$pid', '-o', '$name=']);
    expect(result.exitCode, 0);
    return '${result.stdout}'.trim();
  }

  return {
    'pid': pid,
    'parentPid': int.parse(await field('ppid')),
    'startedAt': await field('lstart'),
    'executable': await field('comm'),
    'commandIdentity': commandIdentity,
  };
}

void main() {
  group('stop process ownership', () {
    test(
      'does not terminate the VM listener of an attach-only session',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'scout_attach_stop_',
        );
        final previous = Directory.current;
        Process? listener;
        addTearDown(() async {
          Directory.current = previous;
          final process = listener;
          if (process != null) {
            process.kill(ProcessSignal.sigterm);
            await process.exitCode.timeout(
              const Duration(seconds: 2),
              onTimeout: () => -1,
            );
          }
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        });

        final script = File(p.join(temp.path, 'foreign_listener.dart'));
        script.writeAsStringSync(r'''
import 'dart:async';
import 'dart:io';

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  stdout.writeln(server.port);
  await stdout.flush();
  await ProcessSignal.sigterm.watch().first;
  await server.close(force: true);
}
''');
        final listenerProcess = await Process.start(
          Platform.resolvedExecutable,
          [script.path],
        );
        listener = listenerProcess;
        final port = int.parse(
          await listenerProcess.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 5)),
        );
        final lsof = await Process.run('lsof', [
          '-tiTCP:$port',
          '-sTCP:LISTEN',
        ]);
        expect(lsof.exitCode, 0, reason: 'test requires listener discovery');
        expect('${lsof.stdout}', contains('${listenerProcess.pid}'));

        Directory.current = temp;
        final session = Directory('.flutter_scout')..createSync();
        File(
          p.join(session.path, 'vm_uri.txt'),
        ).writeAsStringSync('ws://127.0.0.1:$port/ws');
        File(p.join(session.path, 'session_meta.json')).writeAsStringSync(
          jsonEncode({
            'mode': 'attach_only',
            'state': 'ready',
            'runId': 'attach-foreign',
            'vmServiceUri': 'ws://127.0.0.1:$port/ws',
          }),
        );

        expect(await FlutterScoutCli().run(['stop']), 0);
        expect(
          listenerProcess.kill(ProcessSignal.sigterm),
          isTrue,
          reason: 'Scout must not kill a process it only attached to',
        );
        await listenerProcess.exitCode.timeout(const Duration(seconds: 2));
        listener = null;
      },
      onPlatform: const {'windows': Skip('requires POSIX lsof and signals')},
    );

    test(
      'does not terminate a different Flutter run from a reused pid file',
      () async {
        final temp = await Directory.systemTemp.createTemp('scout_pid_reuse_');
        final previous = Directory.current;
        Process? foreignRun;
        addTearDown(() async {
          Directory.current = previous;
          final process = foreignRun;
          if (process != null) {
            process.kill(ProcessSignal.sigterm);
            await process.exitCode.timeout(
              const Duration(seconds: 2),
              onTimeout: () => -1,
            );
          }
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        });

        final fakeFlutter = File(p.join(temp.path, 'flutter'));
        fakeFlutter.writeAsStringSync('''#!/bin/sh
trap 'exit 0' TERM INT
while true; do sleep 1; done
''');
        expect(
          (await Process.run('chmod', ['700', fakeFlutter.path])).exitCode,
          0,
        );
        final project = Directory(p.join(temp.path, 'project'))..createSync();
        final foreignProcess = await Process.start(fakeFlutter.path, [
          'run',
          '--dart-define',
          'FLUTTER_SCOUT_RUN_ID=other-run',
          '--dart-define',
          'FLUTTER_SCOUT_PROJECT=${project.absolute.path}',
        ]);
        foreignRun = foreignProcess;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final identity = await processIdentity(foreignProcess.pid);

        Directory.current = project;
        final session = Directory('.flutter_scout')..createSync();
        File(
          p.join(session.path, 'flutter.pid'),
        ).writeAsStringSync('${foreignProcess.pid}');
        File(p.join(session.path, 'session_meta.json')).writeAsStringSync(
          jsonEncode({
            'mode': 'scout_owned_flutter_run',
            'state': 'ready',
            'runId': 'expected-run',
            'project': project.absolute.path,
            'processIdentity': identity,
          }),
        );

        expect(await FlutterScoutCli().run(['stop']), 0);
        expect(
          foreignProcess.kill(ProcessSignal.sigterm),
          isTrue,
          reason: 'run-token mismatch must fail closed',
        );
        await foreignProcess.exitCode.timeout(const Duration(seconds: 2));
        foreignRun = null;
      },
      onPlatform: const {'windows': Skip('requires POSIX scripts and signals')},
    );

    test(
      'terminates only the Flutter run with matching run and project tokens',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'scout_exact_owner_',
        );
        final previous = Directory.current;
        Process? ownedRun;
        addTearDown(() async {
          Directory.current = previous;
          final process = ownedRun;
          if (process != null) {
            process.kill(ProcessSignal.sigterm);
            await process.exitCode.timeout(
              const Duration(seconds: 2),
              onTimeout: () => -1,
            );
          }
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        });

        final fakeFlutter = File(p.join(temp.path, 'flutter'));
        fakeFlutter.writeAsStringSync('''#!/bin/sh
trap 'exit 0' TERM INT
while true; do sleep 1; done
''');
        expect(
          (await Process.run('chmod', ['700', fakeFlutter.path])).exitCode,
          0,
        );
        const runId = 'owned-run';
        final project = Directory(p.join(temp.path, 'project'))..createSync();
        final ownedProcess = await Process.start(fakeFlutter.path, [
          'run',
          '--dart-define',
          'FLUTTER_SCOUT_RUN_ID=$runId',
          '--dart-define',
          'FLUTTER_SCOUT_PROJECT=${project.absolute.path}',
        ]);
        ownedRun = ownedProcess;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final identity = await processIdentity(ownedProcess.pid);

        Directory.current = project;
        final session = Directory('.flutter_scout')..createSync();
        File(
          p.join(session.path, 'flutter.pid'),
        ).writeAsStringSync('${ownedProcess.pid}');
        File(p.join(session.path, 'session_meta.json')).writeAsStringSync(
          jsonEncode({
            'mode': 'scout_owned_flutter_run',
            'state': 'ready',
            'runId': runId,
            'project': project.absolute.path,
            'processIdentity': identity,
          }),
        );

        expect(await FlutterScoutCli().run(['stop']), 0);
        // A POSIX process terminated by Scout may report either its trap's
        // clean exit or the negative signal number. Completion within the
        // bound, plus the dead-process check below, is the ownership contract.
        await ownedProcess.exitCode.timeout(const Duration(seconds: 2));
        expect(ownedProcess.kill(ProcessSignal.sigterm), isFalse);
        ownedRun = null;
      },
      onPlatform: const {'windows': Skip('requires POSIX scripts and signals')},
    );

    test(
      'does not terminate matching command tokens with a stale start identity',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'scout_stale_identity_',
        );
        final previous = Directory.current;
        Process? reusedRun;
        addTearDown(() async {
          Directory.current = previous;
          final process = reusedRun;
          if (process != null) {
            process.kill(ProcessSignal.sigterm);
            await process.exitCode.timeout(
              const Duration(seconds: 2),
              onTimeout: () => -1,
            );
          }
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        });

        final fakeFlutter = File(p.join(temp.path, 'flutter'));
        fakeFlutter.writeAsStringSync('''#!/bin/sh
trap 'exit 0' TERM INT
while true; do sleep 1; done
''');
        expect(
          (await Process.run('chmod', ['700', fakeFlutter.path])).exitCode,
          0,
        );
        const runId = 'stale-start-run';
        final project = Directory(p.join(temp.path, 'project'))..createSync();
        final process = await Process.start(fakeFlutter.path, [
          'run',
          '--dart-define',
          'FLUTTER_SCOUT_RUN_ID=$runId',
          '--dart-define',
          'FLUTTER_SCOUT_PROJECT=${project.absolute.path}',
        ]);
        reusedRun = process;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final identity = await processIdentity(process.pid);

        Directory.current = project;
        final session = Directory('.flutter_scout')..createSync();
        File(
          p.join(session.path, 'flutter.pid'),
        ).writeAsStringSync('${process.pid}');
        File(p.join(session.path, 'session_meta.json')).writeAsStringSync(
          jsonEncode({
            'mode': 'scout_owned_flutter_run',
            'state': 'ready',
            'runId': runId,
            'project': project.absolute.path,
            'processIdentity': {
              ...identity,
              'startedAt': 'Mon Jan  1 00:00:00 1990',
            },
          }),
        );

        expect(await FlutterScoutCli().run(['stop']), 0);
        expect(
          process.kill(ProcessSignal.sigterm),
          isTrue,
          reason: 'start-time mismatch must fail closed on PID reuse',
        );
        await process.exitCode.timeout(const Duration(seconds: 2));
        reusedRun = null;
      },
      onPlatform: const {'windows': Skip('requires POSIX scripts and signals')},
    );

    test(
      'does not terminate a command-shaped VM log listener with stale identity',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'scout_vm_log_pid_reuse_',
        );
        final previous = Directory.current;
        Process? ownedRun;
        Process? staleListener;
        addTearDown(() async {
          Directory.current = previous;
          for (final process in [staleListener, ownedRun]) {
            if (process == null) continue;
            process.kill(ProcessSignal.sigterm);
            await process.exitCode.timeout(
              const Duration(seconds: 2),
              onTimeout: () => -1,
            );
          }
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        });

        final sleeper = File(p.join(temp.path, 'flutter_scout_sleeper.dart'));
        sleeper.writeAsStringSync(r'''
import 'dart:io';
Future<void> main() async {
  await ProcessSignal.sigterm.watch().first;
}
''');
        final fakeFlutter = File(p.join(temp.path, 'flutter'));
        fakeFlutter.writeAsStringSync('''#!/bin/sh
trap 'exit 0' TERM INT
while true; do sleep 1; done
''');
        expect(
          (await Process.run('chmod', ['700', fakeFlutter.path])).exitCode,
          0,
        );
        const runId = 'listener-owner-run';
        final project = Directory(p.join(temp.path, 'project'))..createSync();
        final session = Directory(p.join(project.path, '.flutter_scout'))
          ..createSync();
        final owner = await Process.start(fakeFlutter.path, [
          'run',
          '--dart-define',
          'FLUTTER_SCOUT_RUN_ID=$runId',
          '--dart-define',
          'FLUTTER_SCOUT_PROJECT=${project.absolute.path}',
        ]);
        ownedRun = owner;
        final listener = await Process.start(Platform.resolvedExecutable, [
          sleeper.path,
          'vm-log-listener',
          '--session-dir',
          session.absolute.path,
          '--owner-pid',
          '${owner.pid}',
        ]);
        staleListener = listener;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final ownerIdentity = await processIdentity(owner.pid);
        final listenerIdentity = await processIdentity(
          listener.pid,
          commandIdentity: 'vm_log_listener',
        );

        Directory.current = project;
        File(
          p.join(session.path, 'flutter.pid'),
        ).writeAsStringSync('${owner.pid}');
        File(
          p.join(session.path, 'vm_log_listener.pid'),
        ).writeAsStringSync('${listener.pid}');
        File(p.join(session.path, 'session_meta.json')).writeAsStringSync(
          jsonEncode({
            'mode': 'scout_owned_flutter_run',
            'state': 'ready',
            'runId': runId,
            'project': project.absolute.path,
            'pid': owner.pid,
            'processIdentity': ownerIdentity,
            'vmLogListenerPid': listener.pid,
            'vmLogListener': {
              'pid': listener.pid,
              'processIdentity': {
                ...listenerIdentity,
                'startedAt': 'Mon Jan  1 00:00:00 1990',
              },
              'ownerPid': owner.pid,
              'ownerProcessIdentity': ownerIdentity,
              'runId': runId,
              'sessionDirectory': session.absolute.path,
            },
          }),
        );

        expect(await FlutterScoutCli().run(['stop']), 0);
        await owner.exitCode.timeout(const Duration(seconds: 2));
        ownedRun = null;
        expect(
          listener.kill(ProcessSignal.sigterm),
          isTrue,
          reason: 'a stale listener tuple must fail closed despite its command',
        );
        await listener.exitCode.timeout(const Duration(seconds: 2));
        staleListener = null;
      },
      onPlatform: const {'windows': Skip('requires POSIX scripts and signals')},
    );

    test(
      'does not terminate a serve-shaped process with stale identity',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'scout_serve_pid_reuse_',
        );
        final previous = Directory.current;
        Process? staleServe;
        addTearDown(() async {
          Directory.current = previous;
          final process = staleServe;
          if (process != null) {
            process.kill(ProcessSignal.sigterm);
            await process.exitCode.timeout(
              const Duration(seconds: 2),
              onTimeout: () => -1,
            );
          }
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        });
        final script = File(p.join(temp.path, 'flutter_scout_serve.dart'));
        script.writeAsStringSync(r'''
import 'dart:io';
Future<void> main() async {
  await ProcessSignal.sigterm.watch().first;
}
''');
        final process = await Process.start(Platform.resolvedExecutable, [
          script.path,
          'serve',
        ]);
        staleServe = process;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final identity = await processIdentity(
          process.pid,
          commandIdentity: 'serve_daemon',
        );

        Directory.current = temp;
        final session = Directory('.flutter_scout')..createSync();
        File(p.join(session.path, 'session_meta.json')).writeAsStringSync(
          jsonEncode({
            'mode': 'attach_only',
            'state': 'ready',
            'serve': {
              'pid': process.pid,
              'port': 65530,
              'instanceId': List<String>.filled(64, 'a').join(),
              'sessionDirectory': session.absolute.path,
              'processIdentity': {
                ...identity,
                'startedAt': 'Mon Jan  1 00:00:00 1990',
              },
            },
          }),
        );

        expect(await FlutterScoutCli().run(['stop']), 0);
        expect(
          process.kill(ProcessSignal.sigterm),
          isTrue,
          reason: 'serve PID reuse must not inherit termination authority',
        );
        await process.exitCode.timeout(const Duration(seconds: 2));
        staleServe = null;
      },
      onPlatform: const {'windows': Skip('requires POSIX scripts and signals')},
    );

    test(
      'terminates only an exact detached supervisor worker',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'scout_exact_supervisor_',
        );
        final previous = Directory.current;
        Process? worker;
        addTearDown(() async {
          Directory.current = previous;
          final process = worker;
          if (process != null) {
            process.kill(ProcessSignal.sigterm);
            await process.exitCode.timeout(
              const Duration(seconds: 2),
              onTimeout: () => -1,
            );
          }
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        });
        final script = File(p.join(temp.path, 'flutter_scout_worker.dart'));
        script.writeAsStringSync(r'''
import 'dart:io';
Future<void> main() async {
  await ProcessSignal.sigterm.watch().first;
}
''');
        final project = Directory(p.join(temp.path, 'project'))..createSync();
        final session = Directory(p.join(project.path, '.flutter_scout'))
          ..createSync();
        const runId = 'exact-supervisor-run';
        final config = File(p.join(session.path, 'worker.json'))
          ..writeAsStringSync(
            jsonEncode({
              'runId': runId,
              'project': project.absolute.path,
              'device': 'test-device',
              'flutterArgs': [
                'run',
                '-d',
                'test-device',
                '--dart-define',
                'FLUTTER_SCOUT_RUN_ID=$runId',
                '--dart-define',
                'FLUTTER_SCOUT_PROJECT=${project.absolute.path}',
              ],
            }),
          );
        final process = await Process.start(Platform.resolvedExecutable, [
          script.path,
          'flutter-run-worker',
          '--config',
          config.absolute.path,
        ]);
        worker = process;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final identity = await processIdentity(
          process.pid,
          commandIdentity: 'flutter_run_worker',
        );
        Directory.current = project;
        File(p.join(session.path, 'session_meta.json')).writeAsStringSync(
          jsonEncode({
            'mode': 'scout_owned_flutter_run',
            'state': 'ready',
            'runId': runId,
            'project': project.absolute.path,
            'device': 'test-device',
            'supervisor': {
              'type': 'detached_process',
              'workerPid': process.pid,
              'runId': runId,
              'configFile': config.absolute.path,
              'processIdentity': identity,
            },
          }),
        );

        expect(await FlutterScoutCli().run(['stop']), 0);
        await process.exitCode.timeout(const Duration(seconds: 2));
        expect(process.kill(ProcessSignal.sigterm), isFalse);
        worker = null;
      },
      onPlatform: const {'windows': Skip('requires POSIX scripts and signals')},
    );

    test(
      'does not terminate a detached supervisor after PID identity mismatch',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'scout_stale_supervisor_',
        );
        final previous = Directory.current;
        Process? staleWorker;
        addTearDown(() async {
          Directory.current = previous;
          final process = staleWorker;
          if (process != null) {
            process.kill(ProcessSignal.sigterm);
            await process.exitCode.timeout(
              const Duration(seconds: 2),
              onTimeout: () => -1,
            );
          }
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        });
        final script = File(
          p.join(temp.path, 'flutter_scout_stale_worker.dart'),
        );
        script.writeAsStringSync(r'''
import 'dart:io';
Future<void> main() async {
  await ProcessSignal.sigterm.watch().first;
}
''');
        final project = Directory(p.join(temp.path, 'project'))..createSync();
        final session = Directory(p.join(project.path, '.flutter_scout'))
          ..createSync();
        const runId = 'stale-supervisor-run';
        final config = File(p.join(session.path, 'worker.json'))
          ..writeAsStringSync(
            jsonEncode({
              'runId': runId,
              'project': project.absolute.path,
              'device': 'test-device',
              'flutterArgs': [
                'run',
                '-d',
                'test-device',
                '--dart-define',
                'FLUTTER_SCOUT_RUN_ID=$runId',
                '--dart-define',
                'FLUTTER_SCOUT_PROJECT=${project.absolute.path}',
              ],
            }),
          );
        final process = await Process.start(Platform.resolvedExecutable, [
          script.path,
          'flutter-run-worker',
          '--config',
          config.absolute.path,
        ]);
        staleWorker = process;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final identity = await processIdentity(
          process.pid,
          commandIdentity: 'flutter_run_worker',
        );
        Directory.current = project;
        File(p.join(session.path, 'session_meta.json')).writeAsStringSync(
          jsonEncode({
            'mode': 'scout_owned_flutter_run',
            'state': 'ready',
            'runId': runId,
            'project': project.absolute.path,
            'device': 'test-device',
            'supervisor': {
              'type': 'detached_process',
              'workerPid': process.pid,
              'runId': runId,
              'configFile': config.absolute.path,
              'processIdentity': {
                ...identity,
                'startedAt': 'Mon Jan  1 00:00:00 1990',
              },
            },
          }),
        );

        expect(await FlutterScoutCli().run(['stop']), 0);
        expect(
          process.kill(ProcessSignal.sigterm),
          isTrue,
          reason: 'a stale worker tuple must not authorize termination',
        );
        await process.exitCode.timeout(const Duration(seconds: 2));
        staleWorker = null;
      },
      onPlatform: const {'windows': Skip('requires POSIX scripts and signals')},
    );

    test(
      'hot-update capability rejects command-shaped stale ownership',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'scout_hot_update_pid_reuse_',
        );
        final previous = Directory.current;
        Process? staleRun;
        addTearDown(() async {
          Directory.current = previous;
          final process = staleRun;
          if (process != null) {
            process.kill(ProcessSignal.sigterm);
            await process.exitCode.timeout(
              const Duration(seconds: 2),
              onTimeout: () => -1,
            );
          }
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        });
        final fakeFlutter = File(p.join(temp.path, 'flutter'));
        fakeFlutter.writeAsStringSync('''#!/bin/sh
trap 'exit 0' TERM INT
while true; do sleep 1; done
''');
        expect(
          (await Process.run('chmod', ['700', fakeFlutter.path])).exitCode,
          0,
        );
        const runId = 'stale-hot-update-run';
        final project = Directory(p.join(temp.path, 'project'))..createSync();
        final process = await Process.start(fakeFlutter.path, [
          'run',
          '--dart-define',
          'FLUTTER_SCOUT_RUN_ID=$runId',
          '--dart-define',
          'FLUTTER_SCOUT_PROJECT=${project.absolute.path}',
        ]);
        staleRun = process;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final identity = await processIdentity(process.pid);

        Directory.current = project;
        final session = Directory('.flutter_scout')..createSync();
        File(
          p.join(session.path, 'flutter.pid'),
        ).writeAsStringSync('${process.pid}');
        File(p.join(session.path, 'session_meta.json')).writeAsStringSync(
          jsonEncode({
            'mode': 'scout_owned_flutter_run',
            'state': 'ready',
            'runId': runId,
            'project': project.absolute.path,
            'processIdentity': {
              ...identity,
              'startedAt': 'Mon Jan  1 00:00:00 1990',
            },
          }),
        );

        final capability = await FlutterScoutCli().debugHotUpdateCapability(
          'ws://127.0.0.1:65529/ws',
        );
        expect((capability['restart'] as Map)['available'], isFalse);
        expect(capability['attachOnly'], isTrue);
        expect(
          capability['ownershipProof'],
          'identity_mismatch_or_unavailable',
        );
        expect(process.kill(ProcessSignal.sigterm), isTrue);
        await process.exitCode.timeout(const Duration(seconds: 2));
        staleRun = null;
      },
      onPlatform: const {'windows': Skip('requires POSIX scripts and signals')},
    );
  });
}
