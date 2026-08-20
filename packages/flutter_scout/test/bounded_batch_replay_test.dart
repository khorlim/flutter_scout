import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('bounded batch preflight', () {
    test('a late invalid command causes zero VM dispatch', () async {
      await _withBoundedInputTemp((temp) async {
        var connections = 0;
        FlutterScoutCli.debugVmServiceConnectObserver = (_) => connections++;

        final exitCode = await FlutterScoutCli().run(<String>[
          'batch',
          'tap btn.first; tap',
        ]);

        expect(exitCode, 1);
        expect(connections, 0);
        expect(_recordedActions(temp), isEmpty);
      });
    });

    test(
      'lifecycle, infrastructure, and recursive commands are forbidden',
      () async {
        await _withBoundedInputTemp((_) async {
          for (final forbidden in <String>[
            'launch --device simulator',
            'reload',
            'serve',
            'batch "tap btn.save"',
            'replay flow.json',
            'record run checkout',
            'vm-log-listener',
          ]) {
            expect(
              await FlutterScoutCli().run(<String>[
                'batch',
                'tap btn.first; $forbidden',
              ]),
              1,
              reason: forbidden,
            );
          }
        });
      },
    );

    test(
      'batch files reject symlinks, invalid UTF-8, and oversized bytes',
      () async {
        await _withBoundedInputTemp((temp) async {
          final invalidUtf8 = File(p.join(temp.path, 'invalid.scout'))
            ..writeAsBytesSync(<int>[0xff, 0xfe]);
          expect(
            await FlutterScoutCli().run(<String>[
              'batch',
              '--file',
              invalidUtf8.path,
            ]),
            1,
          );

          final oversized = File(p.join(temp.path, 'oversized.scout'))
            ..writeAsBytesSync(
              List<int>.filled(1024 * 1024 + 1, 0x61),
              flush: true,
            );
          expect(
            await FlutterScoutCli().run(<String>[
              'batch',
              '--file',
              oversized.path,
            ]),
            1,
          );

          if (!Platform.isWindows) {
            final target = File(p.join(temp.path, 'target.scout'))
              ..writeAsStringSync('tap btn.save');
            final link = Link(p.join(temp.path, 'linked.scout'))
              ..createSync(target.path);
            expect(
              await FlutterScoutCli().run(<String>[
                'batch',
                '--file',
                link.path,
              ]),
              1,
            );
          }
        });
      },
    );

    test('compact batch output keeps independent safety outcomes', () {
      final compact = FlutterScoutCli().debugCompactBatchStep(<String, dynamic>{
        'ok': true,
        'transport': 'ok',
        'dispatch': 'dispatched',
        'observation': 'no_effect',
        'postcondition': 'postcondition_not_requested',
        'runtimeHealth': 'runtime_clean',
        'evidence': const <String, Object?>{'status': 'committed'},
      });

      expect(compact['transport'], 'ok');
      expect(compact['dispatch'], 'dispatched');
      expect(compact['observation'], 'no_effect');
      expect(compact['postcondition'], 'postcondition_not_requested');
      expect(compact['runtimeHealth'], 'runtime_clean');
      expect(compact['businessSuccessClaimed'], isFalse);

      final contradictory = FlutterScoutCli().debugCompactBatchStep(
        <String, dynamic>{
          'ok': true,
          'transport': 'failed',
          'dispatch': 'dispatched',
          'observation': 'changed',
          'postcondition': 'postcondition_met',
          'runtimeHealth': 'runtime_clean',
          'evidence': const <String, Object?>{'status': 'committed'},
        },
      );
      expect(contradictory['outcomeStatus'], 'transport_failed');
      expect(contradictory['outcomeAccepted'], isFalse);
      expect(contradictory['businessSuccessClaimed'], isFalse);
    });

    test(
      'placeholders outside business values and non-string fills preflight closed',
      () async {
        await _withBoundedInputTemp((temp) async {
          var connections = 0;
          FlutterScoutCli.debugVmServiceConnectObserver = (_) => connections++;
          final cases = <String>[
            "tap btn.first; input --target ' VAR:shared' ' VAR:shared'",
            "tap btn.first; fill --json '{\"field\":\" VAR:shared\"}' --expect-text ' VAR:shared'",
            "tap btn.first; fill --json '{\"field\":7}'",
          ];
          for (final script in cases) {
            expect(
              await FlutterScoutCli().run(<String>[
                'batch',
                '--var',
                'shared=protected',
                script,
              ]),
              1,
              reason: script,
            );
          }
          expect(connections, 0);
          expect(_recordedActions(temp), isEmpty);
        });
      },
    );
  });

  group('bounded replay preflight', () {
    test('a late extra field causes zero dispatch', () async {
      await _withBoundedInputTemp((temp) async {
        var connections = 0;
        FlutterScoutCli.debugVmServiceConnectObserver = (_) => connections++;
        final replay = _writeReplay(temp, <Object?>[
          <String, Object?>{'cmd': 'tap', 'target': 'btn.first'},
          <String, Object?>{
            'cmd': 'tap',
            'target': 'btn.second',
            'unexpected': true,
          },
        ]);

        expect(await FlutterScoutCli().run(<String>['replay', replay.path]), 1);
        expect(connections, 0);
        expect(_recordedActions(temp), isEmpty);
      });
    });

    test(
      'non-map, unsupported, and missing-placeholder actions do not dispatch',
      () async {
        await _withBoundedInputTemp((temp) async {
          var connections = 0;
          FlutterScoutCli.debugVmServiceConnectObserver = (_) => connections++;
          final cases = <List<Object?>>[
            <Object?>[
              <String, Object?>{'cmd': 'tap', 'target': 'btn.first'},
              'not-an-action',
            ],
            <Object?>[
              <String, Object?>{'cmd': 'tap', 'target': 'btn.first'},
              <String, Object?>{'cmd': 'restart'},
            ],
            <Object?>[
              <String, Object?>{'cmd': 'tap', 'target': 'btn.first'},
              <String, Object?>{
                'cmd': 'input',
                'target': 'field.secret',
                'value': 'will-be-redacted-before-dispatch',
              },
            ],
            <Object?>[
              <String, Object?>{'cmd': 'tap', 'target': 'btn.first'},
              <String, Object?>{'cmd': 'tap', 'target': 42},
            ],
          ];
          for (var index = 0; index < cases.length; index++) {
            final replay = _writeReplay(
              temp,
              cases[index],
              name: 'case$index.json',
            );
            expect(
              await FlutterScoutCli().run(<String>['replay', replay.path]),
              1,
              reason: 'case $index',
            );
          }
          expect(connections, 0);
          expect(_recordedActions(temp), isEmpty);
        });
      },
    );

    test(
      'placeholders outside replay business values do not dispatch',
      () async {
        await _withBoundedInputTemp((temp) async {
          var connections = 0;
          FlutterScoutCli.debugVmServiceConnectObserver = (_) => connections++;
          final replay = _writeReplay(temp, <Object?>[
            <String, Object?>{
              'cmd': 'input',
              'target': 'field.secret',
              'value': 'plain-is-source-redacted',
              // This deliberately duplicates the placeholder generated for the
              // input value, proving scope checks count locations, not names.
              'expectText': ' VAR:field.secret',
            },
          ]);

          expect(
            await FlutterScoutCli().run(<String>[
              'replay',
              '--var',
              'field.secret=protected',
              replay.path,
            ]),
            1,
          );
          expect(connections, 0);
          expect(_recordedActions(temp), isEmpty);
        });
      },
    );

    test(
      'replay files reject symlinks, invalid UTF-8, oversized and deep JSON',
      () async {
        await _withBoundedInputTemp((temp) async {
          final invalidUtf8 = File(p.join(temp.path, 'invalid.json'))
            ..writeAsBytesSync(<int>[0xff, 0xfe]);
          expect(
            await FlutterScoutCli().run(<String>['replay', invalidUtf8.path]),
            1,
          );

          final oversized = File(p.join(temp.path, 'oversized.json'))
            ..writeAsBytesSync(
              List<int>.filled(1024 * 1024 + 1, 0x20),
              flush: true,
            );
          expect(
            await FlutterScoutCli().run(<String>['replay', oversized.path]),
            1,
          );

          final deep = File(p.join(temp.path, 'deep.json'))
            ..writeAsStringSync(
              '${List<String>.filled(40, '[').join()}0${List<String>.filled(40, ']').join()}',
            );
          expect(await FlutterScoutCli().run(<String>['replay', deep.path]), 1);

          if (!Platform.isWindows) {
            final target = _writeReplay(temp, <Object?>[
              <String, Object?>{'cmd': 'back'},
            ], name: 'target.json');
            final link = Link(p.join(temp.path, 'linked.json'))
              ..createSync(target.path);
            expect(
              await FlutterScoutCli().run(<String>['replay', link.path]),
              1,
            );
          }
        });
      },
    );

    test('empty and over-count inputs cannot report success', () async {
      await _withBoundedInputTemp((temp) async {
        final empty = _writeReplay(temp, const <Object?>[], name: 'empty.json');
        expect(await FlutterScoutCli().run(<String>['replay', empty.path]), 1);

        final tooMany = _writeReplay(temp, <Object?>[
          for (var index = 0; index < 257; index++)
            <String, Object?>{'cmd': 'back'},
        ], name: 'too-many.json');
        expect(
          await FlutterScoutCli().run(<String>['replay', tooMany.path]),
          1,
        );
      });
    });
  });

  group('replay truthfulness', () {
    final base = <String, Object?>{
      'ok': true,
      'transport': 'ok',
      'dispatch': 'dispatched',
      'observation': 'changed',
      'postcondition': 'postcondition_not_requested',
      'runtimeHealth': 'runtime_clean',
      'evidence': const <String, Object?>{'status': 'committed'},
    };

    test('unasserted completion never becomes a business-success claim', () {
      final outcome = FlutterScoutCli().debugAssessReplayOutcome(base);
      expect(outcome['status'], 'completed_unasserted');
      expect(outcome['accepted'], isTrue);
      expect(outcome['businessSuccessClaimed'], isFalse);

      final verified = FlutterScoutCli().debugAssessReplayOutcome(
        <String, Object?>{...base, 'postcondition': 'postcondition_met'},
      );
      expect(verified['status'], 'verified');
      expect(verified['businessSuccessClaimed'], isTrue);
    });

    test(
      'no-effect, unknown, runtime-blocked, and evidence failures are closed',
      () {
        final cases = <String, Map<String, Object?>>{
          'no_effect': <String, Object?>{...base, 'observation': 'no_effect'},
          'dispatch_outcome_unknown': <String, Object?>{
            ...base,
            'dispatch': 'dispatch_outcome_unknown',
            'observation': 'observation_unavailable',
          },
          'runtime_blocked': <String, Object?>{
            ...base,
            'runtimeHealth': 'runtime_blocked',
          },
          'evidence_commit_failed': <String, Object?>{
            ...base,
            'evidence': const <String, Object?>{'status': 'unavailable'},
          },
        };

        for (final entry in cases.entries) {
          final outcome = FlutterScoutCli().debugAssessReplayOutcome(
            entry.value,
          );
          expect(outcome['status'], entry.key);
          expect(outcome['accepted'], isFalse);
          expect(outcome['businessSuccessClaimed'], isFalse);
        }
      },
    );
  });
}

Future<void> _withBoundedInputTemp(
  Future<void> Function(Directory temp) body,
) async {
  final previous = Directory.current;
  final previousRegistry = FlutterScoutCli.debugRegistryPathOverride;
  final previousObserver = FlutterScoutCli.debugVmServiceConnectObserver;
  final temp = Directory.systemTemp.createTempSync('scout_bounded_input_');
  try {
    Directory.current = temp;
    FlutterScoutCli.debugRegistryPathOverride = p.join(
      temp.path,
      'registry.json',
    );
    await body(temp);
  } finally {
    FlutterScoutCli.debugVmServiceConnectObserver = previousObserver;
    FlutterScoutCli.debugRegistryPathOverride = previousRegistry;
    Directory.current = previous;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}

File _writeReplay(
  Directory temp,
  List<Object?> actions, {
  String name = 'replay.json',
}) =>
    File(p.join(temp.path, name))
      ..writeAsStringSync(jsonEncode(actions), flush: true);

List<Object?> _recordedActions(Directory temp) {
  final file = File(p.join(temp.path, '.flutter_scout', 'session.json'));
  if (!file.existsSync()) return const <Object?>[];
  final decoded = jsonDecode(file.readAsStringSync());
  return decoded is List ? decoded : const <Object?>[];
}
