import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final cli = FlutterScoutCli();

  test(
    'public launch and ensure pass exact renderer flag to their Flutter worker',
    () async {
      final entrypoint = p.join(
        Directory.current.path,
        'bin/flutter_scout.dart',
      );
      for (final command in ['launch', 'ensure']) {
        for (final flag in <String?>[
          null,
          '--enable-impeller',
          '--no-enable-impeller',
        ]) {
          final temp = await Directory.systemTemp.createTemp(
            'scout_renderer_argv_',
          );
          try {
            final argv = File(p.join(temp.path, 'argv.txt'));
            final fakeFlutter = File(p.join(temp.path, 'flutter'));
            fakeFlutter.writeAsStringSync('''#!/bin/sh
printf '%s\\n' "\$@" > '${argv.path}'
exit 1
''');
            expect(
              (await Process.run('chmod', ['700', fakeFlutter.path])).exitCode,
              0,
            );
            final result = await Process.run(
              Platform.resolvedExecutable,
              [
                entrypoint,
                '--single-json',
                command,
                '--project',
                temp.path,
                '--device',
                'macos',
                '--inherit-launch-context',
                '--launch-timeout',
                '8',
                '--launch-idle-timeout',
                '3',
                ?flag,
              ],
              workingDirectory: temp.path,
              environment: {
                'HOME': temp.path,
                'PATH': '${temp.path}:${Platform.environment['PATH']}',
              },
            );
            expect(
              result.exitCode,
              1,
              reason: '${result.stdout}\n${result.stderr}',
            );
            expect(
              argv.existsSync(),
              isTrue,
              reason: '${result.stdout}\n${result.stderr}',
            );
            final observed = argv.readAsLinesSync();
            expect(observed.take(3), ['run', '-d', 'macos']);
            expect(
              observed.where((s) => s.contains('enable-impeller')),
              flag == null ? isEmpty : [flag],
            );
            final meta =
                jsonDecode(
                      File(
                        p.join(temp.path, '.flutter_scout/session_meta.json'),
                      ).readAsStringSync(),
                    )
                    as Map;
            expect(
              (meta['rendererRequest'] as Map)['enableImpeller'],
              flag == null ? null : flag == '--enable-impeller',
            );
          } finally {
            temp.deleteSync(recursive: true);
          }
        }
      }
    },
    onPlatform: {'!mac-os': const Skip('macOS fast-path device fixture')},
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'renderer omission leaves Flutter defaults intact; flags retain polarity',
    () {
      for (final requested in <bool?>[null, true, false]) {
        final args = <String>[
          if (requested != null)
            requested ? '--enable-impeller' : '--no-enable-impeller',
        ];
        final result = cli.debugRendererLaunchRequest(args);
        expect(result['flutterArgs'], args);
        expect((result['rendererRequest'] as Map)['enableImpeller'], requested);
        expect(
          (result['rendererRequest'] as Map)['actualRenderer'],
          'not_observed',
        );
        expect(
          cli.debugRendererLaunchRequest(result['flutterArgs'] as List<String>),
          result,
        );
      }
    },
  );

  test('explicit reuse accepts only the same proven owned launch request', () {
    for (final requested in [true, false]) {
      final same = <String, Object?>{
        'rendererRequest': {'enableImpeller': requested},
      };
      expect(
        () => cli.debugValidateRendererReuse(requested, same, owned: true),
        returnsNormally,
      );
      for (final meta in <Map<String, Object?>?>[
        null,
        {},
        {
          'rendererRequest': {'enableImpeller': null},
        },
        {
          'rendererRequest': {'enableImpeller': !requested},
        },
      ]) {
        expect(
          () => cli.debugValidateRendererReuse(requested, meta, owned: true),
          throwsA(
            isA<ScoutCliException>().having(
              (e) => e.code,
              'code',
              'renderer_request_conflict',
            ),
          ),
        );
      }
      expect(
        () => cli.debugValidateRendererReuse(requested, same, owned: false),
        throwsA(
          isA<ScoutCliException>().having(
            (e) => e.code,
            'code',
            'renderer_request_conflict',
          ),
        ),
      );
      expect(
        () => cli.debugValidateRendererReuse(null, same, owned: false),
        returnsNormally,
      );
    }
  });
}
