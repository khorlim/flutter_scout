import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'protected fill and replay variables stay out of argv, output, and artifacts',
    () async {
      final packageRoot = Directory.current.absolute.path;
      final temp = await Directory.systemTemp.createTemp(
        'scout_protected_ingress_',
      );
      try {
        final fillSecret =
            'SCOUT_FILL_SECRET_${DateTime.now().microsecondsSinceEpoch}_$pid';
        final fillFile = _privateFile(
          p.join(temp.path, 'fill.json'),
          jsonEncode(<String, String>{'field.password': fillSecret}),
        );
        final fillArgs = <String>['fill', '--file', fillFile.path];
        _expectProcessArgvHasNoSecret(fillArgs, fillSecret);
        final fill = await _runCli(packageRoot, temp.path, fillArgs);
        expect(fill.exitCode, isNot(0), reason: fill.combined);
        expect(fill.combined, isNot(contains(fillSecret)));
        expect(fill.combined, isNot(contains('invalid_protected_json')));
        fillFile.deleteSync();

        final stdinSecret =
            'SCOUT_STDIN_SECRET_${DateTime.now().microsecondsSinceEpoch}_$pid';
        final stdinArgs = <String>['fill', '--stdin'];
        _expectProcessArgvHasNoSecret(stdinArgs, stdinSecret);
        final fillStdin = await _runCli(
          packageRoot,
          temp.path,
          stdinArgs,
          stdinBytes: utf8.encode(
            jsonEncode(<String, String>{'field.otp': stdinSecret}),
          ),
        );
        expect(fillStdin.exitCode, isNot(0), reason: fillStdin.combined);
        expect(fillStdin.combined, isNot(contains(stdinSecret)));

        final variableSecret =
            'SCOUT_VAR_SECRET_${DateTime.now().microsecondsSinceEpoch}_$pid';
        final variableFile = _privateFile(
          p.join(temp.path, 'variables.json'),
          jsonEncode(<String, String>{'account': variableSecret}),
        );
        final replayFile = File(p.join(temp.path, 'replay.json'))
          ..writeAsStringSync(
            jsonEncode(<Map<String, Object?>>[
              <String, Object?>{
                'cmd': 'input',
                'target': 'field.account',
                'value': ' VAR:account',
                '_redacted': 'true',
              },
            ]),
          );
        final replayArgs = <String>[
          'replay',
          replayFile.path,
          '--var-file',
          variableFile.path,
        ];
        _expectProcessArgvHasNoSecret(replayArgs, variableSecret);
        final replay = await _runCli(packageRoot, temp.path, replayArgs);
        expect(replay.exitCode, isNot(0), reason: replay.combined);
        expect(replay.combined, isNot(contains(variableSecret)));
        expect(replay.combined, isNot(contains('Could not find an option')));
        variableFile.deleteSync();

        final batchSecret =
            'SCOUT_BATCH_SECRET_${DateTime.now().microsecondsSinceEpoch}_$pid';
        final batchArgs = <String>[
          'batch',
          "tap btn.first; input --target field.account ' VAR:missing'",
          '--var-stdin',
        ];
        _expectProcessArgvHasNoSecret(batchArgs, batchSecret);
        final batch = await _runCli(
          packageRoot,
          temp.path,
          batchArgs,
          stdinBytes: utf8.encode(
            jsonEncode(<String, String>{'unrelated': batchSecret}),
          ),
        );
        expect(batch.exitCode, isNot(0));
        expect(batch.combined, contains('missing_var'));
        expect(batch.combined, isNot(contains(batchSecret)));

        _expectDirectoryHasNoSecrets(temp, <String>[
          fillSecret,
          stdinSecret,
          variableSecret,
          batchSecret,
        ]);
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'protected files fail closed without chmodding caller input',
    () async {
      final packageRoot = Directory.current.absolute.path;
      final temp = await Directory.systemTemp.createTemp(
        'scout_protected_ingress_rejections_',
      );
      try {
        if (!Platform.isWindows) {
          final insecure = File(p.join(temp.path, 'insecure.json'))
            ..writeAsStringSync('{"field":"private"}');
          _chmod(insecure.path, '644');
          final insecureResult = await _runCli(packageRoot, temp.path, <String>[
            'fill',
            '--file',
            insecure.path,
          ]);
          expect(
            insecureResult.combined,
            contains('insecure_secret_file_permissions'),
          );
          expect(FileStat.statSync(insecure.path).mode & 0xfff, 0x1a4);

          final target = _privateFile(
            p.join(temp.path, 'target.json'),
            '{"field":"private"}',
          );
          final link = Link(p.join(temp.path, 'link.json'))
            ..createSync(target.path);
          final linkResult = await _runCli(packageRoot, temp.path, <String>[
            'fill',
            '--file',
            link.path,
          ]);
          expect(linkResult.combined, contains('unsafe_secret_file'));
        }

        final directoryResult = await _runCli(packageRoot, temp.path, <String>[
          'fill',
          '--file',
          temp.path,
        ]);
        expect(directoryResult.combined, contains('invalid_secret_file_type'));

        final oversized = File(p.join(temp.path, 'oversized.json'))
          ..writeAsBytesSync(
            List<int>.filled(1024 * 1024 + 1, 0x61),
            flush: true,
          );
        if (!Platform.isWindows) _chmod(oversized.path, '600');
        final oversizedResult = await _runCli(packageRoot, temp.path, <String>[
          'fill',
          '--file',
          oversized.path,
        ]);
        expect(oversizedResult.combined, contains('secret_input_too_large'));

        final malformedUtf8 = File(p.join(temp.path, 'malformed.json'))
          ..writeAsBytesSync(<int>[0x7b, 0xff, 0x7d], flush: true);
        if (!Platform.isWindows) _chmod(malformedUtf8.path, '600');
        final malformedResult = await _runCli(packageRoot, temp.path, <String>[
          'fill',
          '--file',
          malformedUtf8.path,
        ]);
        expect(malformedResult.combined, contains('invalid_secret_input_utf8'));

        final nonString = _privateFile(
          p.join(temp.path, 'non-string.json'),
          '{"field":1234}',
        );
        final nonStringResult = await _runCli(packageRoot, temp.path, <String>[
          'fill',
          '--file',
          nonString.path,
        ]);
        expect(
          nonStringResult.combined,
          contains('invalid_protected_json_value'),
        );

        final controlledName = _privateFile(
          p.join(temp.path, 'controlled-name.json'),
          jsonEncode(<String, String>{'bad\u000aname': 'private'}),
        );
        final controlledResult = await _runCli(packageRoot, temp.path, <String>[
          'batch',
          "input --target field.one ' VAR:bad'",
          '--var-file',
          controlledName.path,
        ]);
        expect(controlledResult.combined, contains('invalid_var_name'));
        expect(controlledResult.combined, isNot(contains('bad\nname')));
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'legacy argv sources emit a structured insecure-source warning',
    () async {
      final packageRoot = Directory.current.absolute.path;
      final temp = await Directory.systemTemp.createTemp(
        'scout_legacy_ingress_warning_',
      );
      try {
        final secret =
            'SCOUT_LEGACY_SECRET_${DateTime.now().microsecondsSinceEpoch}_$pid';
        final result = await _runCli(packageRoot, temp.path, <String>[
          'fill',
          '--json',
          jsonEncode(<String, String>{'field.password': secret}),
        ]);
        expect(result.combined, contains('insecure_secret_source'));
        expect(result.combined, contains('deprecated'));
        expect(result.combined, isNot(contains(secret)));
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
  );

  test(
    'export-batch writes an atomic private retention-labelled artifact',
    () async {
      final packageRoot = Directory.current.absolute.path;
      final temp = await Directory.systemTemp.createTemp(
        'scout_private_batch_export_',
      );
      try {
        final sessionDirectory = Directory(p.join(temp.path, '.flutter_scout'))
          ..createSync();
        File(p.join(sessionDirectory.path, 'session.json')).writeAsStringSync(
          jsonEncode(<Map<String, Object?>>[
            <String, Object?>{
              'cmd': 'input',
              'target': 'field.password',
              'value': ' VAR:field.password',
              '_redacted': 'true',
            },
          ]),
        );
        final output = p.join(temp.path, 'flow.scout');
        final result = await _runCli(packageRoot, temp.path, <String>[
          'export-batch',
          '--output',
          output,
          '--retention',
          '7d',
        ]);
        expect(result.exitCode, 0, reason: result.combined);
        expect(
          File(output).readAsStringSync(),
          contains(' VAR:field.password'),
        );
        final metadata =
            jsonDecode(File('$output.metadata.json').readAsStringSync()) as Map;
        expect(metadata['dataClassification'], 'private_application_data');
        expect((metadata['retentionPolicy'] as Map)['policy'], '7d');
        if (!Platform.isWindows) {
          expect(FileStat.statSync(output).mode & 0xfff, 0x180);
          expect(
            FileStat.statSync('$output.metadata.json').mode & 0xfff,
            0x180,
          );
        }
        expect(
          temp.listSync().where((entity) => entity.path.endsWith('.tmp')),
          isEmpty,
        );
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
  );
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
  List<String> args, {
  List<int>? stdinBytes,
}) async {
  final executableArgs = <String>[
    '--packages=${p.join(packageRoot, '.dart_tool', 'package_config.json')}',
    p.join(packageRoot, 'bin', 'flutter_scout.dart'),
    ...args,
  ];
  if (stdinBytes == null) {
    final result = await Process.run(
      Platform.resolvedExecutable,
      executableArgs,
      workingDirectory: workingDirectory,
    );
    return _CliCapture(
      result.exitCode,
      result.stdout.toString(),
      result.stderr.toString(),
    );
  }
  final process = await Process.start(
    Platform.resolvedExecutable,
    executableArgs,
    workingDirectory: workingDirectory,
  );
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(stdinBytes);
  await process.stdin.close();
  final exitCode = await process.exitCode.timeout(const Duration(seconds: 30));
  return _CliCapture(exitCode, await stdoutFuture, await stderrFuture);
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

void _expectProcessArgvHasNoSecret(List<String> args, String secret) {
  expect(args.join('\u0000'), isNot(contains(secret)));
}

void _expectDirectoryHasNoSecrets(Directory directory, List<String> secrets) {
  final encoded = <List<int>>[
    for (final secret in secrets) utf8.encode(secret),
  ];
  final leaks = <String>[];
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is! File) continue;
    final bytes = entity.readAsBytesSync();
    if (encoded.any((secret) => _containsBytes(bytes, secret))) {
      leaks.add(p.relative(entity.path, from: directory.path));
    }
  }
  expect(leaks, isEmpty, reason: 'protected plaintext leaked into $leaks');
}

bool _containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return true;
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
