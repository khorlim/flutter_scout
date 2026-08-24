import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('performance regressions', () {
    test(
      'local installer compiles a JSON-clean executable after Pub activation',
      () async {
        if (Platform.isWindows) return;
        final temporary = Directory.systemTemp.createTempSync(
          'flutter_scout_installer_test.',
        );
        addTearDown(() {
          if (temporary.existsSync()) temporary.deleteSync(recursive: true);
        });
        final pubCache = Directory(p.join(temporary.path, 'pub-cache'))
          ..createSync();
        final fakeDart = File(p.join(temporary.path, 'dart'))
          ..writeAsStringSync('''#!/bin/sh
set -eu
if [ "\$1" = pub ]; then
  printf '%s\\n' "\$@" > "\$PUB_CACHE/activation-args"
  mkdir -p "\$PUB_CACHE/bin"
  printf '#!/bin/sh\\nprintf pub-wrapper-noise\\n' > "\$PUB_CACHE/bin/flutter-scout"
  chmod +x "\$PUB_CACHE/bin/flutter-scout"
  exit 0
fi
if [ "\$1" = compile ] && [ "\$2" = exe ]; then
  output=''
  while [ "\$#" -gt 0 ]; do
    if [ "\$1" = -o ]; then
      output="\$2"
      shift 2
      continue
    fi
    shift
  done
  mkdir -p "\$(dirname "\$output")"
  printf '#!/bin/sh\\nprintf "{\\\\"ok\\\\":true}\\\\n"\\n' > "\$output"
  chmod +x "\$output"
  exit 0
fi
exit 1
''');
        final chmod = Process.runSync('chmod', <String>['+x', fakeDart.path]);
        expect(chmod.exitCode, 0);
        final repository = p.normalize(
          p.join(Directory.current.path, '..', '..'),
        );
        final installer = p.join(repository, 'tool', 'install-local-shim.sh');
        final result = await Process.run(
          '/bin/sh',
          <String>[installer],
          environment: <String, String>{
            ...Platform.environment,
            'PUB_CACHE': pubCache.path,
            'DART_BIN': fakeDart.path,
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(
          File(p.join(pubCache.path, 'activation-args')).readAsLinesSync(),
          <String>[
            'pub',
            'global',
            'activate',
            '--source',
            'path',
            p.join(repository, 'packages', 'flutter_scout'),
          ],
        );
        final output = jsonDecode(result.stdout.toString()) as Map;
        expect(output['compiledExecutable'], isTrue);
        final installed = File(p.join(pubCache.path, 'bin', 'flutter-scout'));
        expect(installed.existsSync(), isTrue);
        final invocation = await Process.run('/bin/sh', <String>[
          installed.path,
        ]);
        expect(invocation.exitCode, 0, reason: '${invocation.stderr}');
        expect(invocation.stdout, '{"ok":true}\n');
      },
    );

    test(
      'encoded sensitive matcher is reused until the source set changes',
      () {
        final cli = FlutterScoutCli();
        const firstSecret = 'secret-primary-123';
        final first =
            cli.debugSanitizeSerialization(
                  <String, Object?>{
                    'raw': firstSecret,
                    'encoded': base64.encode(utf8.encode(firstSecret)),
                  },
                  sensitiveValues: const <String>[firstSecret],
                )
                as Map;
        expect(first.toString(), isNot(contains(firstSecret)));
        expect(cli.debugSensitiveRedactionMatcherBuildCount, 1);

        cli.debugSanitizeSerialization(
          List<String>.filled(200, 'safe response text'),
          sensitiveValues: const <String>[firstSecret],
        );
        expect(cli.debugSensitiveRedactionMatcherBuildCount, 1);

        cli.debugSanitizeSerialization(
          'secret-secondary-456',
          sensitiveValues: const <String>[firstSecret, 'secret-secondary-456'],
        );
        expect(cli.debugSensitiveRedactionMatcherBuildCount, 2);
      },
    );

    test('event projection stays memory-resident within one CLI process', () {
      _withTemporaryWorkingDirectory((temporary) {
        var diskLoads = 0;
        FlutterScoutCli.debugEventProjectionDiskLoadHook = () => diskLoads++;
        final cli = FlutterScoutCli();
        final cursor = cli.debugAppendEventStrict(<String, Object?>{
          'type': 'command',
          'status': 'started',
          'commandId': 'command-1',
        });
        cli.debugAppendEventStrict(<String, Object?>{
          'type': 'action_result',
          'status': 'completed',
          'commandId': 'command-1',
        });
        cli.debugUpdateEventStrict(
          cursor: cursor,
          commandId: 'command-1',
          updates: const <String, Object?>{'status': 'completed'},
        );
        expect(diskLoads, 0);
        expect(
          File(
            p.join(temporary.path, '.flutter_scout', 'events.jsonl'),
          ).readAsLinesSync(),
          hasLength(2),
        );

        FlutterScoutCli().debugAppendEventStrict(<String, Object?>{
          'type': 'observation',
          'status': 'completed',
          'commandId': 'command-2',
        });
        expect(diskLoads, 1);
      });
    });

    test('unexpired retention cleanup does not rewrite the registry', () {
      _withTemporaryWorkingDirectory((temporary) {
        final cli = FlutterScoutCli();
        final artifact = p.join(
          temporary.path,
          '.flutter_scout',
          'screenshots',
          'retained.png',
        );
        cli.debugWriteRetainedArtifact(
          artifact,
          const <int>[1, 2, 3],
          retention: '24h',
          createdAt: DateTime.utc(2026, 1, 1),
        );

        var writes = 0;
        FlutterScoutCli.debugRetentionRegistryWriteHook = () => writes++;
        final unexpired = cli.debugRetentionCleanup(
          now: DateTime.utc(2026, 1, 1, 12),
        );
        expect(unexpired['registryUpdated'], isFalse);
        expect(writes, 0);
        expect(File(artifact).existsSync(), isTrue);

        final expired = cli.debugRetentionCleanup(
          now: DateTime.utc(2026, 1, 2, 1),
        );
        expect(expired['registryUpdated'], isTrue);
        expect(writes, 1);
        expect(File(artifact).existsSync(), isFalse);
      });
    });
  });
}

void _withTemporaryWorkingDirectory(void Function(Directory) body) {
  final original = Directory.current;
  final temporary = Directory.systemTemp.createTempSync(
    'flutter_scout_performance_test.',
  );
  try {
    Directory.current = temporary;
    body(temporary);
  } finally {
    FlutterScoutCli.debugEventProjectionDiskLoadHook = null;
    FlutterScoutCli.debugRetentionRegistryWriteHook = null;
    Directory.current = original;
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  }
}
