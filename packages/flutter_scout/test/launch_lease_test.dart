import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'kernel launch lease survives malformed metadata and owner crash',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'flutter_scout_launch_lease_',
      );
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
      });
      final sessionDirectory = p.join(root.path, '.flutter_scout');
      final fixture = p.join(
        Directory.current.path,
        'test',
        'fixtures',
        'launch_lease_holder.dart',
      );
      final child = await Process.start(
        Platform.resolvedExecutable,
        <String>['--suppress-analytics', 'run', fixture, sessionDirectory],
        workingDirectory: Directory.current.path,
        environment: <String, String>{
          ...Platform.environment,
          'DART_SUPPRESS_ANALYTICS': 'true',
        },
      );
      var childExited = false;
      final childExit = child.exitCode.then((value) {
        childExited = true;
        return value;
      });
      addTearDown(() async {
        if (!childExited) child.kill(ProcessSignal.sigkill);
        try {
          await childExit.timeout(const Duration(seconds: 5));
        } catch (_) {}
      });

      final stderrText = StringBuffer();
      child.stderr.transform(utf8.decoder).listen(stderrText.write);
      final ready = Completer<Map<String, dynamic>>();
      child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (ready.isCompleted) return;
            try {
              ready.complete(
                Map<String, dynamic>.from(jsonDecode(line) as Map),
              );
            } catch (error, stackTrace) {
              ready.completeError(error, stackTrace);
            }
          });
      final lease =
          await Future.any<Map<String, dynamic>>(<Future<Map<String, dynamic>>>[
            ready.future,
            childExit.then<Map<String, dynamic>>(
              (code) => throw StateError(
                'lease holder exited with $code before ready: $stderrText',
              ),
            ),
          ]).timeout(const Duration(seconds: 15));

      final control = File(lease['controlPath']! as String);
      final info = File(lease['infoPath']! as String);
      expect(control.existsSync(), isTrue);
      expect(info.existsSync(), isTrue);
      if (!Platform.isWindows) {
        expect(FileStat.statSync(control.path).mode & 0x1ff, 0x180);
        expect(FileStat.statSync(info.path).mode & 0x1ff, 0x180);
      }

      // A partial metadata write must never make a live owner's kernel lease
      // look stale or permit a second launch.
      info.writeAsStringSync('{', flush: true);
      final cli = FlutterScoutCli();
      await expectLater(
        cli.debugWithLaunchLease<void>(
          sessionDirectory: sessionDirectory,
          project: root.path,
          device: 'contender-device',
          body: (_) async {},
        ),
        throwsA(
          isA<ScoutCliException>().having(
            (error) => error.code,
            'code',
            'launch_in_progress',
          ),
        ),
      );

      // Kernel locks are released by the OS when a process dies, even though
      // its malformed diagnostic metadata remains.
      expect(child.kill(ProcessSignal.sigkill), isTrue);
      await childExit.timeout(const Duration(seconds: 5));
      expect(control.existsSync(), isTrue);
      expect(info.existsSync(), isTrue);

      await cli.debugWithLaunchLease<void>(
        sessionDirectory: sessionDirectory,
        project: root.path,
        device: 'replacement-device',
        body: (replacement) async {
          final metadata = jsonDecode(info.readAsStringSync()) as Map;
          expect(metadata['runId'], replacement['runId']);
          expect(metadata['lease'], 'kernel_exclusive');

          // POSIX record locks may be process-scoped; the in-process guard
          // independently prevents a re-entrant launch from this CLI process.
          await expectLater(
            cli.debugWithLaunchLease<void>(
              sessionDirectory: sessionDirectory,
              project: root.path,
              device: 'nested-contender',
              body: (_) async {},
            ),
            throwsA(
              isA<ScoutCliException>().having(
                (error) => error.code,
                'code',
                'launch_in_progress',
              ),
            ),
          );
        },
      );

      expect(control.existsSync(), isTrue);
      expect(info.existsSync(), isFalse);
    },
    skip: Platform.isWindows
        ? 'dart:io advisory launch leases are currently POSIX-only'
        : false,
  );
}
