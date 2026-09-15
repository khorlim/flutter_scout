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

  test('VM routing query names do not corrupt factual response strings', () {
    final sanitized =
        FlutterScoutCli().debugSanitizeSerialization(<String, Object?>{
              'vmServiceUri':
                  'http://127.0.0.1:12345/abcdefghijkl/'
                  '?uri=ws%3A%2F%2F127.0.0.1%3A12345%2Fabcdefghijkl%2Fws',
              'scoreKind': 'uncalibrated_heuristic',
            })
            as Map;

    expect(sanitized['vmServiceEndpoint'], isA<Map>());
    expect(sanitized['scoreKind'], 'uncalibrated_heuristic');
  });

  test(
    'agent input/fill persistence and evidence never retain plaintext',
    () async {
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
