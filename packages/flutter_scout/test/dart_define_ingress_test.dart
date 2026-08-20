import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'secret-looking inline defines fail before state or child creation',
    () async {
      final packageRoot = Directory.current.absolute.path;
      final cases = <String>[
        'API_TOKEN=SCOUT_INLINE_NAME_SECRET_7f6a92',
        'PUBLIC_CALLBACK=https://example.test/cb?access_token=SCOUT_QUERY_SECRET_9b104e',
        'PUBLIC_SIGNING=sk-live-SCOUTPREFIXSECRET123456789',
      ];

      for (var index = 0; index < cases.length; index++) {
        final temp = await Directory.systemTemp.createTemp(
          'scout_inline_define_rejection_${index}_',
        );
        try {
          final definition = cases[index];
          final secret = definition.substring(definition.indexOf('=') + 1);
          final markers = RegExp(
            r'SCOUT[A-Z0-9_]+',
          ).allMatches(definition).map((match) => match.group(0)!).toList();
          final result = await _runCli(packageRoot, temp.path, <String>[
            'launch',
            '--device',
            'never-dispatched',
            '--dart-define',
            definition,
          ]);

          expect(result.exitCode, 1, reason: result.combined);
          expect(result.combined, contains('insecure_dart_define_secret'));
          expect(result.combined, contains('not_attempted'));
          expect(result.combined, isNot(contains(definition)));
          expect(result.combined, isNot(contains(secret)));
          for (final marker in markers) {
            expect(result.combined, isNot(contains(marker)));
          }
          expect(
            Directory(p.join(temp.path, '.flutter_scout')).existsSync(),
            isFalse,
            reason: 'rejection must precede session/event persistence',
          );
        } finally {
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'define file contents stay out of worker config, argv, logs, and state',
    () async {
      final packageRoot = Directory.current.absolute.path;
      final temp = await Directory.systemTemp.createTemp(
        'scout_define_file_surface_',
      );
      try {
        final secret =
            'SCOUT_DEFINE_FILE_SECRET_${DateTime.now().microsecondsSinceEpoch}_$pid';
        final defineFile = _privateFile(
          p.join(temp.path, 'defines.json'),
          '${jsonEncode(<String, Object?>{'API_TOKEN': secret, 'BUILD_NUMBER': 42})}\n',
        );
        final prepared = FlutterScoutCli().debugDartDefineFlutterArgs(
          files: <String>[defineFile.path],
        );
        expect(prepared, <String>[
          '--dart-define-from-file',
          defineFile.absolute.path,
        ]);
        expect(prepared.join('\u0000'), isNot(contains(secret)));

        if (Platform.isWindows) return;
        final childArgv = File(p.join(temp.path, 'child-argv.txt'));
        final fakeFlutter = File(p.join(temp.path, 'fake-flutter'))
          ..writeAsStringSync('''#!/bin/sh
for argument in "\$@"; do
  /usr/bin/printf '%s\\n' "\$argument"
done > '${childArgv.path}'
/bin/cat "\$3"
''');
        _chmod(fakeFlutter.path, '700');

        final workerLog = File(p.join(temp.path, 'worker.log'));
        final workerConfig = _privateFile(
          p.join(temp.path, 'worker.json'),
          jsonEncode(<String, Object?>{
            'project': temp.path,
            'flutterExecutable': fakeFlutter.path,
            'flutterArgs': <String>['run', ...prepared],
            'logFile': workerLog.path,
            'persistentConfig': true,
          }),
        );
        expect(workerConfig.readAsStringSync(), isNot(contains(secret)));
        final workerInvocation = <String>[
          'flutter-run-worker',
          '--config',
          workerConfig.path,
        ];
        expect(workerInvocation.join('\u0000'), isNot(contains(secret)));

        final result = await _runCli(packageRoot, temp.path, workerInvocation);
        expect(result.exitCode, 0, reason: result.combined);
        expect(result.combined, isNot(contains(secret)));
        expect(childArgv.readAsStringSync(), isNot(contains(secret)));
        expect(childArgv.readAsLinesSync(), <String>['run', ...prepared]);
        expect(workerLog.readAsStringSync(), contains('<redacted>'));
        expect(workerLog.readAsStringSync(), isNot(contains(secret)));
        expect(
          Directory(p.join(temp.path, '.flutter_scout')).existsSync(),
          isFalse,
          reason:
              'The detached worker must use only its validated absolute config paths and must not bootstrap storage from its working directory.',
        );

        // The parent-side preparation is not treated as lasting authority.
        // A permission change before a later worker start must fail before the
        // child executable observes any arguments.
        childArgv.deleteSync();
        _chmod(defineFile.path, '644');
        final changedAfterPreparation = await _runCli(
          packageRoot,
          temp.path,
          workerInvocation,
        );
        expect(changedAfterPreparation.exitCode, 1);
        expect(
          changedAfterPreparation.combined,
          contains('insecure_secret_file_permissions'),
        );
        expect(changedAfterPreparation.combined, isNot(contains(secret)));
        expect(childArgv.existsSync(), isFalse);
        _expectDirectoryHasNoSecret(
          Directory(p.join(temp.path, '.flutter_scout')),
          secret,
        );
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('define files use the protected owner-only file boundary', () async {
    if (Platform.isWindows) return;
    final packageRoot = Directory.current.absolute.path;
    final temp = await Directory.systemTemp.createTemp(
      'scout_define_file_rejections_',
    );
    try {
      final insecure = File(p.join(temp.path, 'insecure.json'))
        ..writeAsStringSync('{"API_TOKEN":"private"}');
      _chmod(insecure.path, '644');
      final result = await _runCli(packageRoot, temp.path, <String>[
        'ensure',
        '--device',
        'never-dispatched',
        '--dart-define-from-file',
        insecure.path,
      ]);
      expect(result.exitCode, 1, reason: result.combined);
      expect(result.combined, contains('insecure_secret_file_permissions'));
      expect(FileStat.statSync(insecure.path).mode & 0xfff, 0x1a4);
      expect(
        Directory(p.join(temp.path, '.flutter_scout')).existsSync(),
        isFalse,
      );

      final target = _privateFile(
        p.join(temp.path, 'target.json'),
        '{"API_TOKEN":"private"}',
      );
      final link = Link(p.join(temp.path, 'link.json'))
        ..createSync(target.path);
      expect(
        () => FlutterScoutCli().debugDartDefineFlutterArgs(
          files: <String>[link.path],
        ),
        throwsA(
          isA<ScoutCliException>().having(
            (error) => error.code,
            'code',
            'unsafe_secret_file',
          ),
        ),
      );
    } finally {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    }
  });

  test('nonsecret inline defines remain compatible with a warning', () async {
    final packageRoot = Directory.current.absolute.path;
    final temp = await Directory.systemTemp.createTemp(
      'scout_nonsecret_define_warning_',
    );
    try {
      const definition = 'FEATURE_FLAVOR=staging-canary';
      final result = await _runCli(packageRoot, temp.path, const <String>[
        'launch',
        '--dart-define',
        definition,
      ]);
      expect(result.exitCode, 1, reason: result.combined);
      expect(result.combined, contains('insecure_secret_source'));
      expect(result.combined, contains('launch --dart-define'));
      expect(result.combined, contains('missing_device'));
      expect(result.combined, isNot(contains(definition)));
      final events = File(p.join(temp.path, '.flutter_scout', 'events.jsonl'));
      expect(events.readAsStringSync(), contains('[REDACTED]'));
      expect(events.readAsStringSync(), isNot(contains(definition)));

      final help = await _runCli(packageRoot, temp.path, const <String>[
        'help',
        'launch',
      ]);
      expect(help.exitCode, 0);
      expect(help.stdout, contains('--dart-define-from-file'));
      expect(help.stdout, contains('secret-looking'));
      expect(help.stdout, contains('not a secret vault'));
    } finally {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    }
  });
}

class _CliCapture {
  const _CliCapture(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  String get combined => '$stdout\n$stderr';
}

Future<_CliCapture> _runCli(
  String packageRoot,
  String workingDirectory,
  List<String> args,
) async {
  final result = await Process.run(Platform.resolvedExecutable, <String>[
    '--packages=${p.join(packageRoot, '.dart_tool', 'package_config.json')}',
    p.join(packageRoot, 'bin', 'flutter_scout.dart'),
    ...args,
  ], workingDirectory: workingDirectory);
  return _CliCapture(
    result.exitCode,
    result.stdout.toString(),
    result.stderr.toString(),
  );
}

File _privateFile(String path, String value) {
  final file = File(path)..writeAsStringSync(value, flush: true);
  if (!Platform.isWindows) _chmod(path, '600');
  return file;
}

void _chmod(String path, String mode) {
  final result = Process.runSync('/bin/chmod', <String>[mode, path]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
}

void _expectDirectoryHasNoSecret(Directory directory, String secret) {
  if (!directory.existsSync()) return;
  final encoded = utf8.encode(secret);
  final leaks = <String>[];
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is! File) continue;
    if (_containsBytes(entity.readAsBytesSync(), encoded)) {
      leaks.add(p.relative(entity.path, from: directory.path));
    }
  }
  expect(leaks, isEmpty, reason: 'define plaintext leaked into $leaks');
}

bool _containsBytes(List<int> haystack, List<int> needle) {
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    var matches = true;
    for (var index = 0; index < needle.length; index++) {
      if (haystack[start + index] != needle[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
