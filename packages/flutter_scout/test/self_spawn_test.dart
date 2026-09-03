@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final package = Directory.current.path;
  final fixture = p.join(package, 'test', 'fixtures', 'self_spawn_cli.dart');
  late Directory builds;
  late String executable;
  late String snapshot;

  setUpAll(() async {
    builds = await Directory.systemTemp.createTemp('flutter-scout-self-spawn-');
    executable = p.join(builds.path, 'flutter-scout');
    snapshot = p.join(builds.path, 'flutter-scout.jit');
    for (final target in [('exe', executable), ('jit-snapshot', snapshot)]) {
      final compiled = await Process.run(Platform.resolvedExecutable, [
        'compile',
        target.$1,
        '-o',
        target.$2,
        fixture,
      ], workingDirectory: package);
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout}${compiled.stderr}',
      );
    }
  });
  tearDownAll(() async => builds.delete(recursive: true));

  for (final mode in ['source', 'jit', 'aot', 'aot-symlink']) {
    test(
      '$mode launches the generated worker command and private listener',
      () async {
        final temp = await builds.createTemp('run with spaces ');
        final invocation = switch (mode) {
          'source' => [Platform.resolvedExecutable, fixture],
          'jit' => [Platform.resolvedExecutable, snapshot],
          'aot-symlink' => [
            (Link(
              p.join(temp.path, 'flutter-scout-link'),
            )..createSync(executable)).path,
          ],
          _ => [executable],
        };
        Future<ProcessResult> run(List<String> argv) => Process.run(
          argv.first,
          argv.skip(1).toList(),
          workingDirectory: temp.path,
        );
        final config = File(p.join(temp.path, 'worker.json'));
        final stateFile = File(p.join(temp.path, 'state.json'));
        config.writeAsStringSync(
          jsonEncode({
            'project': temp.path,
            'flutterExecutable': '/bin/sh',
            'flutterArgs': ['-c', 'exit 7'],
            'logFile': p.join(temp.path, 'flutter.log'),
            'runId': 'compiled-worker-test',
            'stateFile': stateFile.path,
            'exitFile': p.join(temp.path, 'exit.json'),
            'persistentConfig': true,
            'supervised': true,
          }),
        );
        final plist = await run([
          ...invocation,
          '--probe-plist',
          config.path,
          p.join(temp.path, 'output.log'),
        ]);
        expect(plist.exitCode, 0, reason: '${plist.stderr}');
        final argumentsXml = RegExp(
          r'<key>ProgramArguments</key>\s*<array>(.*?)</array>',
          dotAll: true,
        ).firstMatch('${plist.stdout}')!.group(1)!;
        final workerArgv = RegExp(
          r'<string>(.*?)</string>',
        ).allMatches(argumentsXml).map((match) => match.group(1)!).toList();
        final worker = await run(workerArgv);
        expect(worker.exitCode, 0, reason: '${worker.stdout}${worker.stderr}');
        final state = jsonDecode(stateFile.readAsStringSync()) as Map;
        expect(state['exitCode'], 7);
        expect(state['launchCount'], 1);
        expect(state['workerExitingNormally'], isTrue);
        expect(
          (state['workerProcessIdentity'] as Map)['commandIdentity'],
          'flutter_run_worker',
        );
        expect(
          Directory(p.join(temp.path, '.flutter_scout')).existsSync(),
          isFalse,
        );

        final probe = await run([
          ...invocation,
          '--probe-listener',
          p.join(temp.path, '.flutter_scout', 'listener.log'),
        ]);
        expect(probe.exitCode, 0, reason: '${probe.stderr}');
        final spec = jsonDecode('${probe.stdout}') as Map;
        final listenerArgs = (spec['arguments'] as List).cast<String>();
        final credential = File(spec['uriFile'] as String);
        expect(
          listenerArgs.join(' '),
          isNot(contains('COMPILED_LISTENER_SENTINEL')),
        );
        expect(credential.statSync().mode & 0x3f, 0);
        final listener = await run([workerArgv.first, ...listenerArgs]);
        expect(
          listener.exitCode,
          0,
          reason: '${listener.stdout}${listener.stderr}',
        );
        expect(
          credential.existsSync(),
          isFalse,
          reason:
              'A correctly routed listener consumes its private URI handoff.',
        );
        expect(
          '${listener.stdout}${listener.stderr}',
          isNot(contains('COMPILED_LISTENER_SENTINEL')),
        );
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );
  }
}
