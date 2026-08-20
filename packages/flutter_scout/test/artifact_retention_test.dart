import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('private artifact retention registry', () {
    test('is owner-only and records strict strong identity evidence', () async {
      await _withRetentionTemp((temp) async {
        final cli = FlutterScoutCli();
        final artifact = p.join(
          temp.path,
          '.flutter_scout',
          'screenshots',
          'screen.png',
        );
        cli.debugWriteRetainedArtifact(
          artifact,
          const <int>[0x89, 0x50, 0x4e, 0x47],
          retention: '24h',
          createdAt: DateTime.utc(2026, 1, 1),
        );

        final status = cli.debugRetentionStatus();
        expect(status['registry'], 'valid');
        expect(status['entryCount'], 1);
        final entry = (status['entries']! as List).single as Map;
        expect(
          entry['artifactPath'],
          p.normalize(File(artifact).resolveSymbolicLinksSync()),
        );
        expect(entry['policy'], '24h');
        expect(entry['expiresAt'], '2026-01-02T00:00:00.000Z');
        final identity = entry['artifactIdentity']! as Map;
        expect(identity['kind'], 'file');
        expect(identity['size'], 4);
        expect(identity['sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(
          identity['canonicalPath'],
          p.normalize(File(artifact).resolveSymbolicLinksSync()),
        );
        expect(entry['metadataIdentity'], isA<Map>());

        if (!Platform.isWindows) {
          expect(_mode(p.dirname(cli.debugRetentionRegistryPath)), 0x1c0);
          expect(_mode(cli.debugRetentionRegistryPath), 0x180);
          expect(_mode('${cli.debugRetentionRegistryPath}.lock'), 0x180);
          expect(_mode(artifact), 0x180);
          expect(_mode('$artifact.metadata.json'), 0x180);
        }
      });
    });

    test(
      'expires only 24h and 7d policies while preserving session and manual',
      () async {
        await _withRetentionTemp((temp) async {
          final cli = FlutterScoutCli();
          final created = DateTime.utc(2026, 2, 1, 12);
          String artifact(String name) =>
              p.join(temp.path, '.flutter_scout', 'screenshots', '$name.png');

          for (final policy in const <String>[
            '24h',
            '7d',
            'session',
            'manual',
          ]) {
            cli.debugWriteRetainedArtifact(
              artifact(policy),
              utf8.encode(policy),
              retention: policy,
              createdAt: created,
            );
          }

          final after25Hours = cli.debugRetentionCleanup(
            now: created.add(const Duration(hours: 25)),
          );
          expect(after25Hours['ok'], isTrue);
          expect(after25Hours['deleted'], 1);
          expect(File(artifact('24h')).existsSync(), isFalse);
          expect(File(artifact('7d')).existsSync(), isTrue);
          expect(File(artifact('session')).existsSync(), isTrue);
          expect(File(artifact('manual')).existsSync(), isTrue);

          final afterEightDays = cli.debugRetentionCleanup(
            now: created.add(const Duration(days: 8)),
          );
          expect(afterEightDays['ok'], isTrue);
          expect(afterEightDays['deleted'], 1);
          expect(File(artifact('7d')).existsSync(), isFalse);
          expect(File(artifact('session')).existsSync(), isTrue);
          expect(File(artifact('manual')).existsSync(), isTrue);
        });
      },
    );

    test('command start performs expiry cleanup', () async {
      await _withRetentionTemp((temp) async {
        final cli = FlutterScoutCli();
        final artifact = p.join(
          temp.path,
          '.flutter_scout',
          'screenshots',
          'expired.png',
        );
        cli.debugWriteRetainedArtifact(
          artifact,
          const <int>[1, 2, 3],
          retention: '24h',
          createdAt: DateTime.now().toUtc().subtract(const Duration(days: 2)),
        );

        expect((await _captureRun(cli, const <String>['version'])).exitCode, 0);
        expect(File(artifact).existsSync(), isFalse);
        expect(File('$artifact.metadata.json').existsSync(), isFalse);
      });
    });

    test(
      'command start does not invent an absent retention registry',
      () async {
        await _withRetentionTemp((temp) async {
          final run = await _captureRun(FlutterScoutCli(), const <String>[
            'version',
          ]);
          expect(run.exitCode, 0);
          expect(
            Directory(
              p.join(temp.path, '.flutter_scout', 'retention'),
            ).existsSync(),
            isFalse,
          );
        });
      },
    );

    test(
      'session clear deletes exact session entries but preserves manual and unexpired',
      () async {
        await _withRetentionTemp((temp) async {
          final cli = FlutterScoutCli();
          final base = p.join(temp.path, '.flutter_scout', 'screenshots');
          final session = p.join(base, 'session.png');
          final manual = p.join(base, 'manual.png');
          final unexpired = p.join(base, 'later.png');
          final created = DateTime.now().toUtc();
          cli.debugWriteRetainedArtifact(
            session,
            const <int>[1],
            retention: 'session',
            createdAt: created,
          );
          cli.debugWriteRetainedArtifact(
            manual,
            const <int>[2],
            retention: 'manual',
            createdAt: created,
          );
          cli.debugWriteRetainedArtifact(
            unexpired,
            const <int>[3],
            retention: '24h',
            createdAt: created,
          );

          final sessionRoot = Directory(p.join(temp.path, '.flutter_scout'));
          final managedResidue = <File>[
            File(p.join(sessionRoot.path, 'runs', 'run-a', 'worker.json')),
            File(p.join(sessionRoot.path, '.private', 'vm-uri.txt')),
            File(p.join(sessionRoot.path, 'idempotency', 'receipt.json')),
            File(p.join(sessionRoot.path, 'logs.txt')),
            File(p.join(sessionRoot.path, 'annotations.json')),
          ];
          for (final file in managedResidue) {
            file.parent.createSync(recursive: true);
            file.writeAsStringSync('private managed state');
          }
          final recording = File(
            p.join(sessionRoot.path, 'recordings', 'manual-flow.json'),
          );
          recording.parent.createSync(recursive: true);
          recording.writeAsStringSync('[]');

          final stopped = await _captureRun(cli, const <String>[
            'stop',
            '--clear-session',
          ]);
          expect(stopped.exitCode, 0);
          final response = jsonDecode(stopped.stdout) as Map;
          expect(response['sessionCleared'], isTrue);
          expect(
            (response['managedSessionCleanup']
                as Map)['unexpectedResidualCount'],
            0,
          );
          expect(File(session).existsSync(), isFalse);
          expect(File('$session.metadata.json').existsSync(), isFalse);
          expect(File(manual).existsSync(), isTrue);
          expect(File(unexpired).existsSync(), isTrue);
          for (final file in managedResidue) {
            expect(file.existsSync(), isFalse, reason: file.path);
          }
          expect(recording.readAsStringSync(), '[]');

          final remaining = sessionRoot
              .listSync(recursive: true, followLinks: false)
              .map((entity) => p.relative(entity.path, from: sessionRoot.path));
          for (final path in remaining) {
            expect(
              path == 'retention' ||
                  path == p.join('retention', 'registry.v1.json') ||
                  path == p.join('retention', 'registry.v1.json.lock') ||
                  path == 'recordings' ||
                  path == p.join('recordings', 'manual-flow.json') ||
                  path == 'screenshots' ||
                  path == p.relative(manual, from: sessionRoot.path) ||
                  path ==
                      p.relative(
                        '$manual.metadata.json',
                        from: sessionRoot.path,
                      ) ||
                  path == p.relative(unexpired, from: sessionRoot.path) ||
                  path ==
                      p.relative(
                        '$unexpired.metadata.json',
                        from: sessionRoot.path,
                      ),
              isTrue,
              reason: 'unexpected session residue: $path',
            );
          }
          final status = cli.debugRetentionStatus();
          expect(status['entryCount'], 2);
          expect(
            (status['entries']! as List).map(
              (entry) => (entry as Map)['policy'],
            ),
            containsAll(<String>['manual', '24h']),
          );
        });
      },
    );

    test('session clear preserves and reports unregistered residue', () async {
      await _withRetentionTemp((temp) async {
        final cli = FlutterScoutCli();
        final residue = File(
          p.join(temp.path, '.flutter_scout', 'caller-unknown.bin'),
        );
        residue.parent.createSync(recursive: true);
        residue.writeAsBytesSync(const <int>[9, 9, 9]);
        File? linkTarget;
        Link? unsafeLink;
        if (!Platform.isWindows) {
          linkTarget = File(p.join(temp.path, 'caller-link-target.txt'))
            ..writeAsStringSync('preserve');
          unsafeLink = Link(
            p.join(temp.path, '.flutter_scout', 'caller-unknown.link'),
          )..createSync(linkTarget.path);
        }

        final stopped = await _captureRun(cli, const <String>[
          'stop',
          '--clear-session',
        ]);
        expect(stopped.exitCode, 1);
        final response = jsonDecode(stopped.stdout) as Map;
        expect(response['ok'], isFalse);
        expect(response['sessionCleared'], isFalse);
        final cleanup = response['managedSessionCleanup'] as Map;
        expect(cleanup['ok'], isFalse);
        expect(cleanup['unexpectedResidualCount'], greaterThanOrEqualTo(1));
        expect(
          cleanup['unexpectedResidualPaths'],
          contains('caller-unknown.bin'),
        );
        expect(residue.readAsBytesSync(), const <int>[9, 9, 9]);
        if (unsafeLink != null && linkTarget != null) {
          expect(
            cleanup['unexpectedResidualPaths'],
            contains('caller-unknown.link'),
          );
          expect(
            FileSystemEntity.typeSync(unsafeLink.path, followLinks: false),
            FileSystemEntityType.link,
          );
          expect(linkTarget.readAsStringSync(), 'preserve');
        }
      });
    });

    test(
      'session clear removes an empty expired registry under its lock',
      () async {
        await _withRetentionTemp((temp) async {
          final cli = FlutterScoutCli();
          final artifact = p.join(
            temp.path,
            '.flutter_scout',
            'screenshots',
            'session-only.png',
          );
          cli.debugWriteRetainedArtifact(artifact, const <int>[
            1,
            2,
          ], retention: 'session');
          final registry = cli.debugRetentionRegistryPath;

          final stopped = await _captureRun(cli, const <String>[
            'stop',
            '--clear-session',
          ]);
          expect(stopped.exitCode, 0);
          final response = jsonDecode(stopped.stdout) as Map;
          final cleanup = response['managedSessionCleanup'] as Map;
          expect(cleanup['emptyRetentionRegistryRemoved'], isTrue);
          expect(cleanup['retentionLockPreservedForSerialization'], isTrue);
          expect(File(artifact).existsSync(), isFalse);
          expect(File(registry).existsSync(), isFalse);
          expect(File('$registry.lock').existsSync(), isTrue);
        });
      },
    );

    test(
      'outside-session cleanup touches only the exact registered files',
      () async {
        await _withRetentionTemp((temp) async {
          final cli = FlutterScoutCli();
          final outside = Directory(p.join(temp.path, 'caller-output'))
            ..createSync();
          if (!Platform.isWindows) {
            expect(
              Process.runSync('chmod', <String>['755', outside.path]).exitCode,
              0,
            );
            expect(_mode(outside.path), 0x1ed);
          }
          final tracked = p.join(outside.path, 'tracked.png');
          final sibling = File(p.join(outside.path, 'caller-owned.txt'))
            ..writeAsStringSync('keep');
          cli.debugWriteRetainedArtifact(tracked, const <int>[
            4,
            5,
            6,
          ], retention: 'session');

          final result = cli.debugRetentionCleanup(
            now: DateTime.now().toUtc(),
            includeSession: true,
          );
          expect(result['ok'], isTrue);
          expect(File(tracked).existsSync(), isFalse);
          expect(File('$tracked.metadata.json').existsSync(), isFalse);
          expect(sibling.readAsStringSync(), 'keep');
          expect(outside.existsSync(), isTrue);
          if (!Platform.isWindows) expect(_mode(outside.path), 0x1ed);
        });
      },
    );

    test('artifacts cannot overlap retention control storage', () async {
      await _withRetentionTemp((temp) async {
        final cli = FlutterScoutCli();
        final controls = p.dirname(cli.debugRetentionRegistryPath);
        final artifact = p.join(controls, 'private-output.bin');

        expect(
          () => cli.debugWriteRetainedArtifact(artifact, const <int>[
            1,
            2,
            3,
          ], retention: 'session'),
          throwsA(
            isA<ScoutCliException>().having(
              (error) => error.code,
              'code',
              'unsafe_retention_target',
            ),
          ),
        );
        expect(File(artifact).existsSync(), isFalse);
        expect(File(cli.debugRetentionRegistryPath).existsSync(), isFalse);
      });
    });

    test(
      'record export is retained without chmodding a 0755 caller parent',
      () async {
        await _withRetentionTemp((temp) async {
          final cli = FlutterScoutCli();
          cli.debugRecordAction(<String, Object?>{
            'cmd': 'tap',
            'target': 'button.save',
          });
          expect(
            (await _captureRun(cli, const <String>[
              'record',
              'save-last',
              'retention-export',
            ])).exitCode,
            0,
          );
          final callerParent = Directory(p.join(temp.path, 'caller-exports'))
            ..createSync();
          if (!Platform.isWindows) {
            expect(
              Process.runSync('chmod', <String>[
                '755',
                callerParent.path,
              ]).exitCode,
              0,
            );
          }
          final output = p.join(callerParent.path, 'flow.json');
          expect(
            (await _captureRun(cli, <String>[
              'record',
              'export',
              'retention-export',
              '--out',
              output,
              '--retention',
              'manual',
            ])).exitCode,
            0,
          );
          expect(jsonDecode(File(output).readAsStringSync()), isA<List>());
          final metadata =
              jsonDecode(File('$output.metadata.json').readAsStringSync())
                  as Map;
          expect((metadata['retentionPolicy'] as Map)['policy'], 'manual');
          if (!Platform.isWindows) {
            expect(_mode(callerParent.path), 0x1ed);
            expect(_mode(output), 0x180);
            expect(_mode('$output.metadata.json'), 0x180);
          }
          final status = cli.debugRetentionStatus();
          expect(
            (status['entries']! as List).where(
              (entry) =>
                  (entry as Map)['artifactPath'] ==
                  p.normalize(File(output).resolveSymbolicLinksSync()),
            ),
            hasLength(1),
          );
          final cleanup = cli.debugRetentionCleanup(
            now: DateTime.now().toUtc(),
            includeSession: true,
          );
          expect(cleanup['ok'], isTrue);
          expect(File(output).existsSync(), isTrue);
        });
      },
    );

    test(
      'caller-modified replacements are preserved with typed failure',
      () async {
        await _withRetentionTemp((temp) async {
          final cli = FlutterScoutCli();
          final artifact = p.join(temp.path, 'caller-output', 'replace.png');
          cli.debugWriteRetainedArtifact(
            artifact,
            const <int>[7, 8, 9],
            retention: '24h',
            createdAt: DateTime.utc(2026, 1, 1),
          );
          File(artifact).writeAsBytesSync(const <int>[9, 8, 7, 6]);

          final result = cli.debugRetentionCleanup(
            now: DateTime.utc(2026, 1, 3),
          );
          expect(result['ok'], isFalse);
          expect(result['preserved'], 1);
          expect(
            ((result['failures']! as List).single as Map)['reason'],
            'artifact_identity_changed_or_unsafe',
          );
          expect(File(artifact).readAsBytesSync(), const <int>[9, 8, 7, 6]);
          expect(File('$artifact.metadata.json').existsSync(), isTrue);

          // The valid registry surfaces a typed warning but does not make an
          // unrelated read-only command unusable.
          final unrelated = await _captureRun(cli, const <String>['version']);
          expect(unrelated.exitCode, 0);
          final warning = jsonDecode(unrelated.stderr) as Map;
          expect(warning['messageType'], 'warning');
          expect(
            (warning['warning'] as Map)['code'],
            'retention_cleanup_incomplete',
          );
          expect(warning['commandId'], isA<String>());
          expect(warning['payloadBounds'], isA<Map>());
          expect(File(artifact).existsSync(), isTrue);

          final managedLog = File(
            p.join(temp.path, '.flutter_scout', 'logs.txt'),
          )..writeAsStringSync('private log');
          final stopped = await _captureRun(cli, const <String>[
            'stop',
            '--clear-session',
          ]);
          expect(stopped.exitCode, 1);
          final stoppedResponse = jsonDecode(stopped.stdout) as Map;
          expect(stoppedResponse['sessionCleared'], isFalse);
          expect(
            (stoppedResponse['privateArtifactRetentionCleanup'] as Map)['ok'],
            isFalse,
          );
          expect(
            (stoppedResponse['managedSessionCleanup'] as Map)['ok'],
            isTrue,
          );
          expect(managedLog.existsSync(), isFalse);
          expect(File(artifact).existsSync(), isTrue);
        });
      },
    );

    test('symlink swaps never delete the link target', () async {
      if (Platform.isWindows) return;
      await _withRetentionTemp((temp) async {
        final cli = FlutterScoutCli();
        final artifact = p.join(temp.path, 'caller-output', 'swap.png');
        final target = File(p.join(temp.path, 'do-not-delete.txt'))
          ..writeAsStringSync('caller-data');
        cli.debugWriteRetainedArtifact(artifact, const <int>[
          1,
          3,
          3,
          7,
        ], retention: 'session');
        File(artifact).deleteSync();
        Link(artifact).createSync(target.path);

        final result = cli.debugRetentionCleanup(
          now: DateTime.now().toUtc(),
          includeSession: true,
        );
        expect(result['ok'], isFalse);
        expect(result['preserved'], 1);
        expect(
          FileSystemEntity.typeSync(artifact, followLinks: false),
          FileSystemEntityType.link,
        );
        expect(target.readAsStringSync(), 'caller-data');
      });
    });

    test('modified directory bundles are preserved as a whole', () async {
      await _withRetentionTemp((temp) async {
        final cli = FlutterScoutCli();
        final bundle = Directory(p.join(temp.path, 'bundle'))..createSync();
        File(p.join(bundle.path, 'summary.json')).writeAsStringSync('{}');
        cli.debugRegisterRetainedDirectory(bundle.path, retention: 'session');
        File(p.join(bundle.path, 'caller-added.txt')).writeAsStringSync('new');

        final result = cli.debugRetentionCleanup(
          now: DateTime.now().toUtc(),
          includeSession: true,
        );
        expect(result['ok'], isFalse);
        expect(bundle.existsSync(), isTrue);
        expect(File(p.join(bundle.path, 'summary.json')).existsSync(), isTrue);
        expect(
          File(p.join(bundle.path, 'caller-added.txt')).readAsStringSync(),
          'new',
        );
      });
    });

    test('directory bundle registration refuses symlink members', () async {
      if (Platform.isWindows) return;
      await _withRetentionTemp((temp) async {
        final cli = FlutterScoutCli();
        final target = File(p.join(temp.path, 'caller-target.txt'))
          ..writeAsStringSync('preserve');
        final bundle = Directory(p.join(temp.path, 'bundle'))..createSync();
        Link(p.join(bundle.path, 'alias.txt')).createSync(target.path);

        expect(
          () => cli.debugRegisterRetainedDirectory(
            bundle.path,
            retention: 'session',
          ),
          throwsA(
            isA<ScoutCliException>().having(
              (error) => error.code,
              'code',
              'retention_identity_unavailable',
            ),
          ),
        );
        expect(target.readAsStringSync(), 'preserve');
      });
    });

    test(
      'malformed or torn registry is preserved and deletes nothing',
      () async {
        await _withRetentionTemp((temp) async {
          final cli = FlutterScoutCli();
          final artifact = p.join(temp.path, 'caller-output', 'private.png');
          cli.debugWriteRetainedArtifact(artifact, const <int>[
            2,
            4,
            6,
            8,
          ], retention: 'session');
          final registry = File(cli.debugRetentionRegistryPath);
          registry.writeAsStringSync('{"schemaVersion":1,');
          final tornBytes = registry.readAsBytesSync();

          expect(
            () => cli.debugRetentionCleanup(
              now: DateTime.now().toUtc(),
              includeSession: true,
            ),
            throwsA(
              isA<ScoutCliException>().having(
                (error) => error.code,
                'code',
                'retention_registry_invalid',
              ),
            ),
          );
          expect(registry.readAsBytesSync(), tornBytes);
          expect(File(artifact).existsSync(), isTrue);
          expect(File('$artifact.metadata.json').existsSync(), isTrue);

          final later = p.join(temp.path, 'caller-output', 'later.png');
          expect(
            () => cli.debugWriteRetainedArtifact(later, const <int>[
              1,
            ], retention: 'session'),
            throwsA(
              isA<ScoutCliException>().having(
                (error) => error.code,
                'code',
                'retention_registry_invalid',
              ),
            ),
          );
          expect(File(later).existsSync(), isFalse);
          expect(File('$later.metadata.json').existsSync(), isFalse);

          final commandStart = await _captureRun(cli, const <String>[
            'version',
          ]);
          expect(commandStart.exitCode, 1);
          expect(commandStart.stdout, isEmpty);
          final error = jsonDecode(commandStart.stderr) as Map;
          expect((error['error'] as Map)['code'], 'retention_registry_invalid');
          expect(error['commandId'], isA<String>());
          expect(registry.readAsBytesSync(), tornBytes);

          final stopped = await _captureRun(cli, const <String>[
            'stop',
            '--clear-session',
          ]);
          expect(stopped.exitCode, 1);
          expect(stopped.stderr, isEmpty);
          final stoppedResponse = jsonDecode(stopped.stdout) as Map;
          expect(stoppedResponse['sessionCleared'], isFalse);
          expect(
            (stoppedResponse['error'] as Map)['code'],
            'retention_registry_invalid',
          );
          final retentionCleanup =
              stoppedResponse['privateArtifactRetentionCleanup'] as Map;
          expect(retentionCleanup['registry'], 'invalid');
          expect(retentionCleanup['cleanup'], 'not_performed');
          final managedCleanup =
              stoppedResponse['managedSessionCleanup'] as Map;
          expect(managedCleanup['cleanup'], 'not_performed');
          expect(
            managedCleanup['skippedReason'],
            'retention_control_state_unavailable',
          );
          expect(registry.readAsBytesSync(), tornBytes);
          expect(File(artifact).existsSync(), isTrue);
        });
      },
    );

    test('registry symlink swaps are typed and preserve the target', () async {
      if (Platform.isWindows) return;
      await _withRetentionTemp((temp) async {
        final cli = FlutterScoutCli();
        final artifact = p.join(temp.path, 'caller-output', 'private.png');
        cli.debugWriteRetainedArtifact(artifact, const <int>[
          2,
          4,
        ], retention: 'session');
        final registry = File(cli.debugRetentionRegistryPath);
        final outside = File(p.join(temp.path, 'caller-registry.json'))
          ..writeAsStringSync(registry.readAsStringSync());
        final outsideBytes = outside.readAsBytesSync();
        registry.deleteSync();
        Link(registry.path).createSync(outside.path);

        expect(
          () => cli.debugRetentionCleanup(
            now: DateTime.now().toUtc(),
            includeSession: true,
          ),
          throwsA(
            isA<ScoutCliException>().having(
              (error) => error.code,
              'code',
              'retention_registry_invalid',
            ),
          ),
        );
        expect(outside.readAsBytesSync(), outsideBytes);
        expect(File(artifact).existsSync(), isTrue);
      });
    });

    test(
      'concurrent writers serialize without losing registry entries',
      () async {
        await _withRetentionTemp((temp) async {
          final sessionDirectory = p.join(temp.path, '.flutter_scout');
          final outputDirectory = Directory(p.join(temp.path, 'parallel'))
            ..createSync();
          await Future.wait(<Future<void>>[
            for (var index = 0; index < 12; index++)
              Isolate.run(() {
                FlutterScoutRetentionDebug.debugUseSessionDirectory(
                  sessionDirectory,
                );
                try {
                  FlutterScoutCli().debugWriteRetainedArtifact(
                    p.join(outputDirectory.path, 'artifact_$index.bin'),
                    <int>[index, index + 1],
                    retention: index.isEven ? 'session' : 'manual',
                  );
                } finally {
                  FlutterScoutRetentionDebug.debugUseSessionDirectory(null);
                }
              }),
          ]);

          FlutterScoutRetentionDebug.debugUseSessionDirectory(sessionDirectory);
          final status = FlutterScoutCli().debugRetentionStatus();
          expect(status['registry'], 'valid');
          expect(status['entryCount'], 12);
          final paths = (status['entries']! as List)
              .map((entry) => (entry as Map)['artifactPath'])
              .toSet();
          expect(paths, hasLength(12));
        });
      },
    );
  });
}

Future<void> _withRetentionTemp(
  Future<void> Function(Directory temp) body,
) async {
  final previousDirectory = Directory.current;
  final temp = Directory.systemTemp.createTempSync('scout_retention_test_');
  FlutterScoutRetentionDebug.debugUseSessionDirectory(null);
  Directory.current = temp.path;
  try {
    await body(temp);
  } finally {
    FlutterScoutRetentionDebug.debugUseSessionDirectory(null);
    Directory.current = previousDirectory.path;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}

int _mode(String path) => FileStat.statSync(path).mode & 0x1ff;

Future<_CapturedRun> _captureRun(
  FlutterScoutCli cli,
  List<String> arguments,
) async {
  final capturedOut = _CapturedStdout();
  final capturedErr = _CapturedStdout();
  late final int exitCode;
  await IOOverrides.runZoned(
    () async {
      exitCode = await cli.run(arguments);
    },
    stdout: () => capturedOut,
    stderr: () => capturedErr,
  );
  return _CapturedRun(
    exitCode: exitCode,
    stdout: capturedOut.text,
    stderr: capturedErr.text,
  );
}

final class _CapturedRun {
  const _CapturedRun({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

final class _CapturedStdout implements Stdout {
  final StringBuffer _buffer = StringBuffer();

  String get text => _buffer.toString();

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  void add(List<int> data) =>
      _buffer.write(utf8.decode(data, allowMalformed: true));

  @override
  Future<void> close() async {}

  @override
  Future<void> flush() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
