import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('registered multiline secrets and record delimiters are sanitized', () {
    final cli = FlutterScoutCli();
    const secret = 'first-line\nsecond-line\u001b[31m';
    final sanitized =
        cli.debugSanitizeSerialization(
              {
                'message':
                    'Authorization: Bearer $secret\r\nnext\tfield\u0000\u0085\u2028\u2029',
              },
              sensitiveValues: const [secret],
            )
            as Map;
    final message = sanitized['message']! as String;

    expect(message, isNot(contains('first-line')));
    expect(message, isNot(contains('second-line')));
    expect(message, contains('<redacted>'));
    expect(message, contains(r'\r'));
    expect(message, contains(r'\n'));
    expect(message, contains(r'\t'));
    expect(message, contains(r'\u0000'));
    expect(message, contains(r'\u0085'));
    expect(message, contains(r'\u2028'));
    expect(message, contains(r'\u2029'));
    expect(message, isNot(matches(RegExp(r'[\x00-\x1f\x7f-\x9f]'))));
  });

  test(
    'generated input/fill secret never reaches artifacts or process argv',
    () async {
      final packageRoot = Directory.current.absolute.path;
      await _withPrivacyTempCwd((temp) async {
        final sentinel =
            'SCOUT_SENTINEL_${DateTime.now().microsecondsSinceEpoch}_$pid';
        final cli = FlutterScoutCli();

        cli.debugRecordAction({
          'cmd': 'input',
          'target': 'field.account_name',
          'value': sentinel,
        });
        cli.debugRecordAction({
          'cmd': 'fill',
          'values': jsonEncode({
            'field.email': sentinel,
            'field.note': 'prefix-$sentinel-suffix',
          }),
        });

        final sessionFile = File(
          p.join(temp.path, '.flutter_scout', 'session.json'),
        );
        final session = jsonDecode(sessionFile.readAsStringSync()) as List;
        final input = Map<String, Object?>.from(session.first as Map);
        final fill = Map<String, Object?>.from(session.last as Map);
        expect(input['_redacted'], 'true');
        expect(input['value'], ' VAR:field.account_name');
        expect(fill['_redacted'], 'true');
        expect(
          (fill['values'] as Map).values,
          everyElement(startsWith(' VAR:')),
        );

        expect(
          cli.debugResolveRecordedAction(input, {
            'field.account_name': sentinel,
          })['value'],
          sentinel,
        );
        final resolvedFill = cli.debugResolveRecordedAction(fill, {
          'field.email': sentinel,
          'field.note': 'prefix-$sentinel-suffix',
        });
        expect(jsonDecode(resolvedFill['values']!)['field.email'], sentinel);

        final batchScript = [
          'input --target field.batch ${FlutterScoutCli.quoteBatchArg(sentinel)}',
          'fill --json ${FlutterScoutCli.quoteBatchArg(jsonEncode({'field.batch': sentinel}))}',
        ].join('; ');
        expect(
          await cli.run(['batch', batchScript, '--keep-going']),
          1,
          reason: 'the privacy batch intentionally has no attached app',
        );

        expect(
          await cli.run([
            'record',
            'save-last',
            'privacy-flow',
            '--last',
            '2',
            '--feature',
            'privacy',
          ]),
          0,
        );
        final exportPath = p.join(temp.path, 'privacy-flow.json');
        expect(
          await cli.run([
            'record',
            'export',
            'privacy-flow',
            '--feature',
            'privacy',
            '--out',
            exportPath,
          ]),
          0,
        );
        final batchPath = p.join(temp.path, 'privacy-flow.scout');
        expect(await cli.run(['export-batch', '--output', batchPath]), 0);
        final evidencePath = p.join(temp.path, 'evidence');
        expect(
          await cli.run(['evidence', '--output', evidencePath, '--last', '1']),
          0,
        );

        final sanitizedDiagnostic = jsonEncode(
          cli.debugSanitizeSerialization(
            {
              'ok': false,
              'error': {
                'message': 'helper rejected value=$sentinel',
                'details': [sentinel],
              },
            },
            sensitiveValues: [sentinel],
          ),
        );
        expect(sanitizedDiagnostic, isNot(contains(sentinel)));
        expect(sanitizedDiagnostic, contains('<redacted>'));

        final show = await Process.run(Platform.resolvedExecutable, [
          '--packages=${p.join(packageRoot, '.dart_tool', 'package_config.json')}',
          p.join(packageRoot, 'bin', 'flutter_scout.dart'),
          'record',
          'show',
          'privacy-flow',
          '--feature',
          'privacy',
          '--steps',
        ], workingDirectory: temp.path);
        expect(show.exitCode, 0, reason: '${show.stderr}');
        expect('${show.stdout}${show.stderr}', isNot(contains(sentinel)));

        final withoutVars = await Process.run(Platform.resolvedExecutable, [
          '--packages=${p.join(packageRoot, '.dart_tool', 'package_config.json')}',
          p.join(packageRoot, 'bin', 'flutter_scout.dart'),
          'replay',
          exportPath,
        ], workingDirectory: temp.path);
        expect(withoutVars.exitCode, isNot(0));
        expect(
          '${withoutVars.stdout}${withoutVars.stderr}',
          allOf(contains('missing_var'), isNot(contains(sentinel))),
        );

        final vmCredential =
            'ws://127.0.0.1:12345/VM_URI_SENTINEL_$sentinel/ws';
        expect(cli.debugRedactLogText(vmCredential), isNot(contains(sentinel)));
        final launchSpec = cli.debugVmLogListenerLaunchSpec(
          vmUri: vmCredential,
          logFile: p.join(temp.path, '.flutter_scout', 'vm.log'),
          ownerPid: pid,
        );
        final arguments = (launchSpec['arguments'] as List).cast<String>();
        final uriFile = File(launchSpec['uriFile']! as String);
        expect(arguments.join('\n'), isNot(contains(sentinel)));
        expect(arguments, contains('--vm-uri-file'));
        expect(arguments, isNot(contains('--vm-uri')));
        expect(uriFile.readAsStringSync(), vmCredential);
        if (!Platform.isWindows) {
          expect(FileStat.statSync(uriFile.path).mode & 0x3f, 0);
          expect(FileStat.statSync(uriFile.parent.path).mode & 0x3f, 0);
        }
        uriFile.deleteSync();

        final leaks = <String>[];
        final needle = utf8.encode(sentinel);
        for (final entity in temp.listSync(recursive: true)) {
          if (entity is! File) continue;
          if (_containsBytes(entity.readAsBytesSync(), needle)) {
            leaks.add(p.relative(entity.path, from: temp.path));
          }
        }
        expect(leaks, isEmpty, reason: 'sentinel leaked into $leaks');
      });
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

bool _containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    var matches = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (haystack[start + offset] != needle[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

Future<void> _withPrivacyTempCwd(
  Future<void> Function(Directory temp) body,
) async {
  final previous = Directory.current;
  final temp = await Directory.systemTemp.createTemp(
    'flutter_scout_privacy_test_',
  );
  try {
    Directory.current = temp;
    await body(temp);
  } finally {
    Directory.current = previous;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}
