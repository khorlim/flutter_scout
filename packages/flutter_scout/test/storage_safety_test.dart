import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group(
    'private artifact storage',
    () {
      test(
        'uses 0700 directories and 0600 files throughout the session',
        () async {
          await _withStorageTempCwd((temp) async {
            final cli = FlutterScoutCli();
            cli.debugRecordAction({'cmd': 'tap', 'target': 'button.save'});
            expect(
              await cli.run([
                'record',
                'save-last',
                'permission-check',
                '--feature',
                'storage',
              ]),
              0,
            );
            expect(await cli.run(['evidence', '--last', '1']), 0);
            final listener = cli.debugVmLogListenerLaunchSpec(
              vmUri: 'ws://127.0.0.1:8181/credential/ws',
              logFile: p.join(temp.path, '.flutter_scout', 'logs.txt'),
              ownerPid: pid,
            );
            expect(File(listener['uriFile']! as String).existsSync(), isTrue);

            final root = Directory(p.join(temp.path, '.flutter_scout'));
            for (final entity in <FileSystemEntity>[
              root,
              ...root.listSync(recursive: true, followLinks: false),
            ]) {
              final type = FileSystemEntity.typeSync(
                entity.path,
                followLinks: false,
              );
              if (type == FileSystemEntityType.directory) {
                expect(
                  _permissions(entity.path),
                  0x1c0,
                  reason: '${entity.path} must be owner-only 0700',
                );
              } else if (type == FileSystemEntityType.file) {
                expect(
                  _permissions(entity.path),
                  0x180,
                  reason: '${entity.path} must be owner-only 0600',
                );
              }
            }
          });
        },
      );

      test('refuses symlinked session roots and artifact files', () async {
        await _withStorageTempCwd((temp) async {
          final outside = Directory(p.join(temp.path, 'outside'))..createSync();
          Link(p.join(temp.path, '.flutter_scout')).createSync(outside.path);

          expect(
            FlutterScoutCli().debugEnsurePrivateStorage,
            throwsA(
              isA<ScoutCliException>().having(
                (error) => error.code,
                'code',
                'unsafe_storage_path',
              ),
            ),
          );
        });

        await _withStorageTempCwd((temp) async {
          final session = Directory(p.join(temp.path, '.flutter_scout'))
            ..createSync();
          final outside = File(p.join(temp.path, 'outside.json'))
            ..writeAsStringSync('untouched');
          Link(p.join(session.path, 'session.json')).createSync(outside.path);

          expect(
            () => FlutterScoutCli().debugRecordAction({
              'cmd': 'tap',
              'target': 'button.save',
            }),
            throwsA(
              isA<ScoutCliException>().having(
                (error) => error.code,
                'code',
                'unsafe_storage_path',
              ),
            ),
          );
          expect(outside.readAsStringSync(), 'untouched');
        });
      });

      test(
        'atomic writes preserve committed state and events recover a torn tail',
        () async {
          await _withStorageTempCwd((temp) async {
            final cli = FlutterScoutCli();
            cli.debugAtomicSessionWrite('state.json', '{"state":"stable"}');
            final state = File(
              p.join(temp.path, '.flutter_scout', 'state.json'),
            );
            File(
              p.join(state.parent.path, '.state.json.interrupted-writer.tmp'),
            ).writeAsStringSync('{"state":');
            expect(jsonDecode(state.readAsStringSync()), {'state': 'stable'});
            cli.debugAtomicSessionWrite('state.json', '{"state":"new"}');
            expect(jsonDecode(state.readAsStringSync()), {'state': 'new'});

            final events = File(
              p.join(temp.path, '.flutter_scout', 'events.jsonl'),
            );
            events.writeAsStringSync(
              '${jsonEncode({'type': 'first', 'eventCursor': 1})}\n{"torn":',
            );
            cli.debugAppendEventStrict({
              'type': 'second',
              'commandId': 'cmd-2',
            });
            final rows = events
                .readAsLinesSync()
                .map((line) => jsonDecode(line) as Map<String, dynamic>)
                .toList();
            expect(rows.map((row) => row['type']), ['first', 'second']);
            expect(rows.map((row) => row['eventCursor']), [1, 2]);
            expect(rows.last['previousEventCursor'], 1);
            expect(rows.last['correlationId'], 'cmd-2');
          });
        },
      );

      test(
        'runtime log cursors expose complete records and reject drift',
        () async {
          await _withStorageTempCwd((temp) async {
            final cli = FlutterScoutCli();
            cli.debugAtomicSessionWrite('logs.txt', 'one\npartial');

            final first = cli.debugReadScoutLog();
            expect(first['lines'], <String>['one']);
            expect(first['startCursor'], 0);
            expect(first['endCursor'], 4);
            expect(first['observedFileLength'], 11);
            expect(first['pendingBytes'], 7);

            File(
              p.join(temp.path, '.flutter_scout', 'logs.txt'),
            ).writeAsStringSync(' tail\n', mode: FileMode.append, flush: true);
            final second = cli.debugReadScoutLog(sinceCursor: 4);
            expect(second['lines'], <String>['partial tail']);
            expect(second['startCursor'], 4);
            expect(second['endCursor'], 17);
            expect(second['observedFileLength'], 17);
            expect(second['pendingBytes'], 0);

            cli.debugAtomicSessionWrite('logs.txt', 'zero\none\ntwo\n');
            final boundary = cli.debugReadScoutLog(sinceCursor: 5, maxBytes: 8);
            expect(boundary['lines'], <String>['one', 'two']);
            expect(boundary['startCursor'], 5);
            expect(boundary['endCursor'], 13);
            expect(boundary['truncated'], isFalse);

            final middle = cli.debugReadScoutLog(sinceCursor: 6, maxBytes: 8);
            expect(middle['lines'], <String>['two']);
            expect(middle['startCursor'], 9);
            expect(middle['endCursor'], 13);
            expect(middle['truncated'], isTrue);

            expect(
              () => cli.debugReadScoutLog(sinceCursor: 14),
              throwsA(
                isA<ScoutCliException>().having(
                  (error) => error.code,
                  'code',
                  'runtime_log_changed',
                ),
              ),
            );

            final outsideLog = File(p.join(temp.path, 'outside.log'))
              ..writeAsStringSync('private\n');
            cli.debugAtomicSessionWrite(
              'session_meta.json',
              jsonEncode(<String, Object?>{
                'mode': 'scout_owned_flutter_run',
                'runId': 'run-safe',
                'logFile': outsideLog.path,
              }),
            );
            expect(
              () => cli.debugResolvedScoutLogFile,
              throwsA(
                isA<ScoutCliException>().having(
                  (error) => error.code,
                  'code',
                  'unsafe_storage_path',
                ),
              ),
            );
          });
        },
      );

      test(
        'segmented event history remains lossless beyond its projection',
        () async {
          await _withStorageTempCwd((temp) async {
            final cli = FlutterScoutCli();
            final reservation = cli.debugAppendEventStrict(<String, Object?>{
              'type': 'command',
              'status': 'started',
              'commandId': 'cmd-reserved-oldest',
            });
            for (var index = 0; index < 300; index++) {
              cli.debugAppendEventStrict(<String, Object?>{
                'type': 'observation',
                'commandId': 'cmd-$index',
                'status': 'completed',
              });
            }

            final projection = File(
              p.join(temp.path, '.flutter_scout', 'events.jsonl'),
            );
            expect(projection.readAsLinesSync(), hasLength(256));
            expect(
              Directory(
                p.join(temp.path, '.flutter_scout', 'events', 'segments'),
              ).listSync(),
              hasLength(greaterThanOrEqualTo(2)),
            );

            cli.debugUpdateEventStrict(
              cursor: reservation,
              commandId: 'cmd-reserved-oldest',
              updates: const <String, Object?>{
                'status': 'completed',
                'exitCode': 0,
              },
            );
            final durable = cli.debugReadEventJournal();
            expect(durable, hasLength(301));
            expect(
              durable.map((row) => row['eventCursor']),
              orderedEquals(List<int>.generate(301, (index) => index + 1)),
            );
            expect(durable.first['status'], 'completed');
            expect(durable.first['exitCode'], 0);

            // The public tail is a derived projection. Corrupting it must not
            // corrupt or truncate durable history; the next append repairs it.
            projection.writeAsStringSync('{"torn":');
            expect(
              cli.debugAppendEventStrict(<String, Object?>{
                'type': 'observation',
                'commandId': 'cmd-after-repair',
                'status': 'completed',
              }),
              302,
            );
            expect(cli.debugReadEventJournal(), hasLength(302));
            expect(projection.readAsLinesSync(), hasLength(256));
          });
        },
        timeout: const Timeout(Duration(minutes: 1)),
      );

      test(
        'command evidence reserves once before dispatch and completes in place',
        () async {
          await _withStorageTempCwd((temp) async {
            final cli = FlutterScoutCli();
            final cursor = cli.debugAppendEventStrict({
              'schemaVersion': 1,
              'type': 'command',
              'status': 'started',
              'evidenceStatus': 'reserved_before_dispatch',
              'commandId': 'cmd-reserved',
              'command': 'tap',
            });
            cli.debugUpdateEventStrict(
              cursor: cursor,
              commandId: 'cmd-reserved',
              updates: const {
                'status': 'completed',
                'evidenceStatus': 'complete',
                'exitCode': 0,
              },
            );

            final events = File(
              p.join(temp.path, '.flutter_scout', 'events.jsonl'),
            );
            final rows = events
                .readAsLinesSync()
                .map((line) => jsonDecode(line) as Map<String, dynamic>)
                .toList(growable: false);
            expect(rows, hasLength(1));
            expect(rows.single['eventCursor'], cursor);
            expect(rows.single['commandId'], 'cmd-reserved');
            expect(rows.single['status'], 'completed');
            expect(rows.single['evidenceStatus'], 'complete');
            expect(rows.single['exitCode'], 0);

            expect(
              () => cli.debugUpdateEventStrict(
                cursor: cursor,
                commandId: 'different-command',
                updates: const {'status': 'completed'},
              ),
              throwsA(
                isA<ScoutCliException>().having(
                  (error) => error.code,
                  'code',
                  'event_reservation_missing',
                ),
              ),
            );
          });
        },
      );

      test('normal command leaves one complete reserved journal row', () async {
        await _withStorageTempCwd((temp) async {
          expect(await FlutterScoutCli().run(['status']), 0);
          final rows = File(
            p.join(temp.path, '.flutter_scout', 'events.jsonl'),
          ).readAsLinesSync().map((line) => jsonDecode(line) as Map).toList();
          expect(rows, hasLength(1));
          expect(rows.single['type'], 'command');
          expect(rows.single['status'], 'completed');
          expect(rows.single['evidenceStatus'], 'complete');
          expect(rows.single['eventCursor'], 1);
          expect(rows.single['previousEventCursor'], isNull);
          expect(rows.single['finishedAt'], isNotNull);
        });
      });

      test(
        'action success becomes uncertain failure when evidence cannot commit',
        () async {
          await _withStorageTempCwd((temp) async {
            final cli = FlutterScoutCli()..debugEnsurePrivateStorage();
            final outside = File(p.join(temp.path, 'outside-events.jsonl'))
              ..writeAsStringSync('keep\n');
            final events = p.join(temp.path, '.flutter_scout', 'events.jsonl');
            Link(events).createSync(outside.path);

            final result = cli.debugCommitActionEvidence(
              method: 'ext.flutter_scout.tap',
              result: const <String, dynamic>{
                'ok': true,
                'dispatch': 'dispatched',
                'observation': 'changed',
                'postcondition': 'postcondition_met',
              },
              record: const {'cmd': 'tap', 'target': 'button.save'},
            );

            expect(result['ok'], isFalse);
            expect(
              (result['error'] as Map)['code'],
              'action_evidence_persistence_failed',
            );
            expect(result['mutationMayHaveOccurred'], isTrue);
            expect((result['evidence'] as Map)['eventJournal'], 'failed');
            expect((result['evidence'] as Map)['actionJournal'], 'failed');
            final phases = ((result['timings'] as Map)['phases'] as Map);
            expect(phases.keys.toSet(), <String>{
              'connect',
              'snapshot',
              'match',
              'dispatch',
              'settle',
              'delta',
              'logs',
              'serialize',
            });
            expect((phases['serialize'] as Map)['status'], 'measured');
            expect(
              (phases['serialize'] as Map)['boundary'],
              'action_event_journal',
            );
            expect(outside.readAsStringSync(), 'keep\n');
          });
        },
      );

      test(
        'concurrent CLI writers produce one ordered cursor sequence',
        () async {
          final packageRoot = Directory.current.absolute.path;
          final executable = p.join(packageRoot, 'bin', 'flutter_scout.dart');
          await _withStorageTempCwd((temp) async {
            final results = await Future.wait([
              for (var index = 0; index < 8; index++)
                Process.run(
                  Platform.resolvedExecutable,
                  [executable, 'status'],
                  workingDirectory: temp.path,
                  environment: const {
                    'FLUTTER_SCOUT_DEBUG_STORAGE_ERRORS': '1',
                  },
                ),
            ]);
            final storageErrors = results
                .map((result) => result.stderr)
                .join('\n');
            expect(
              results.map((result) => result.exitCode),
              everyElement(0),
              reason: storageErrors,
            );

            final rows = File(
              p.join(temp.path, '.flutter_scout', 'events.jsonl'),
            ).readAsLinesSync().map((line) => jsonDecode(line) as Map).toList();
            expect(rows, hasLength(8), reason: storageErrors);
            expect(rows.map((row) => row['eventCursor']), [
              1,
              2,
              3,
              4,
              5,
              6,
              7,
              8,
            ]);
            expect(
              rows.map((row) => row['correlationId']),
              everyElement(isNot(isEmpty)),
            );
          });
        },
      );

      test(
        'evidence and screenshot metadata declare privacy and retention',
        () async {
          await _withStorageTempCwd((temp) async {
            final cli = FlutterScoutCli();
            if (!Platform.isWindows) {
              expect(
                Process.runSync('chmod', <String>['755', temp.path]).exitCode,
                0,
              );
            }
            final evidence = p.join(temp.path, 'private-evidence');
            expect(
              await cli.run([
                'evidence',
                '--output',
                evidence,
                '--last',
                '1',
                '--retention',
                '24h',
              ]),
              0,
            );
            if (!Platform.isWindows) expect(_permissions(temp.path), 0x1ed);
            final missingAncestor = p.join(
              temp.path,
              'caller-missing-parent',
              'evidence',
            );
            expect(
              await cli.run([
                'evidence',
                '--output',
                missingAncestor,
                '--last',
                '1',
              ]),
              1,
            );
            expect(
              Directory(
                p.join(temp.path, 'caller-missing-parent'),
              ).existsSync(),
              isFalse,
            );
            final summary =
                jsonDecode(
                      File(p.join(evidence, 'summary.json')).readAsStringSync(),
                    )
                    as Map<String, dynamic>;
            expect(summary['dataClassification'], 'private_application_data');
            expect(summary['telemetryCollected'], isFalse);
            expect((summary['retentionPolicy'] as Map)['policy'], '24h');
            expect((summary['retentionPolicy'] as Map)['expiresAt'], isNotNull);
            final provenance = summary['provenance'] as Map;
            expect(provenance['evidenceSchemaVersion'], 1);
            expect(provenance['artifactKind'], 'flutter_scout_evidence_bundle');
            expect(
              (provenance['tool'] as Map)['version'],
              FlutterScoutCli.packageVersion,
            );
            expect((provenance['protocol'] as Map)['cliProtocolMin'], 15);
            expect(
              (provenance['platform'] as Map)['hostOperatingSystem'],
              isNotEmpty,
            );
            final missingEvidence = summary['missingEvidence'] as List;
            expect(
              missingEvidence.whereType<Map>().map((item) => item['field']),
              containsAll(<String>[
                'source.cliCommit',
                'source.appCommit',
                'toolchain.flutterVersion',
                'benchmark.seed',
                'benchmark.hiddenOracle',
              ]),
            );
            expect(_permissions(evidence), 0x1c0);
            expect(_permissions(p.join(evidence, 'summary.json')), 0x180);

            final screenshot = p.join(
              temp.path,
              '.flutter_scout',
              'screenshots',
              'fixture.png',
            );
            cli.debugWritePrivateArtifact(screenshot, const [
              0x89,
              0x50,
              0x4e,
              0x47,
            ], retention: '7d');
            final metadata =
                jsonDecode(File('$screenshot.metadata.json').readAsStringSync())
                    as Map<String, dynamic>;
            expect(metadata['dataClassification'], 'private_application_data');
            expect(metadata['telemetryCollected'], isFalse);
            expect((metadata['retentionPolicy'] as Map)['policy'], '7d');
            expect(_permissions(screenshot), 0x180);
            expect(_permissions('$screenshot.metadata.json'), 0x180);

            final evidenceIndex =
                jsonDecode(
                      File(
                        p.join(
                          temp.path,
                          '.flutter_scout',
                          'evidence',
                          'index.json',
                        ),
                      ).readAsStringSync(),
                    )
                    as Map<String, dynamic>;
            expect(
              evidenceIndex['dataClassification'],
              'private_application_data',
            );
            expect((evidenceIndex['bundles'] as List), hasLength(1));

            expect(await cli.run(['stop', '--clear-session']), 0);
            // Session clear selects only the `session` policy. This explicitly
            // unexpired 7d artifact and its exact metadata remain registered.
            expect(File(screenshot).existsSync(), isTrue);
            expect(File('$screenshot.metadata.json').existsSync(), isTrue);
            expect(Directory(p.dirname(screenshot)).existsSync(), isTrue);
          });
        },
      );

      test('registry rewrites are atomic and owner-only', () async {
        await _withStorageTempCwd((temp) async {
          final registryDirectory = Directory(p.join(temp.path, 'registry'))
            ..createSync();
          final registry = p.join(registryDirectory.path, 'registry.json');
          FlutterScoutCli.debugRegistryPathOverride = registry;
          addTearDown(() => FlutterScoutCli.debugRegistryPathOverride = null);
          File(registry).writeAsStringSync(
            jsonEncode({'missing': p.join(temp.path, 'does-not-exist')}),
          );

          expect(await FlutterScoutCli().run(['apps', '--prune']), 0);
          expect(jsonDecode(File(registry).readAsStringSync()), isEmpty);
          expect(_permissions(registryDirectory.path), 0x1c0);
          expect(_permissions(registry), 0x180);
          expect(_permissions('$registry.lock'), 0x180);

          final outside = File(p.join(temp.path, 'outside-registry.json'))
            ..writeAsStringSync('{"keep":"me"}');
          File(registry).deleteSync();
          Link(registry).createSync(outside.path);
          expect(await FlutterScoutCli().run(['apps', '--prune']), 1);
          expect(outside.readAsStringSync(), '{"keep":"me"}');
        });
      });

      test(
        'annotation and serve sinks are atomic, private, and symlink-safe',
        () async {
          await _withStorageTempCwd((temp) async {
            final cli = FlutterScoutCli();
            cli.debugWriteAnnotationManifest(const <Map<String, Object?>>[
              <String, Object?>{'id': 'ann_001', 'note': 'private note'},
            ]);
            final manifest = p.join(
              temp.path,
              '.flutter_scout',
              'annotations.json',
            );
            expect(_permissions(manifest), 0x180);

            final crop = p.join(
              temp.path,
              '.flutter_scout',
              'crops',
              'ann_001_before.png',
            );
            cli.debugWriteAnnotationCrop(crop, const <int>[1, 2, 3, 4]);
            expect(File(crop).readAsBytesSync(), <int>[1, 2, 3, 4]);
            expect(_permissions(crop), 0x180);

            final outside = File(p.join(temp.path, 'outside-private'))
              ..writeAsStringSync('untouched');
            File(manifest).deleteSync();
            Link(manifest).createSync(outside.path);
            expect(
              () =>
                  cli.debugWriteAnnotationManifest(const <Map<String, Object?>>[
                    <String, Object?>{'id': 'ann_002'},
                  ]),
              throwsA(
                isA<ScoutCliException>().having(
                  (error) => error.code,
                  'code',
                  'unsafe_storage_path',
                ),
              ),
            );
            expect(outside.readAsStringSync(), 'untouched');

            File(crop).deleteSync();
            Link(crop).createSync(outside.path);
            expect(
              () => cli.debugWriteAnnotationCrop(crop, const <int>[9]),
              throwsA(isA<ScoutCliException>()),
            );
            expect(outside.readAsStringSync(), 'untouched');

            final callerDirectory = Directory(
              p.join(temp.path, 'caller-output'),
            )..createSync();
            Process.runSync('chmod', <String>['755', callerDirectory.path]);
            final portFile = p.join(callerDirectory.path, 'serve.port');
            final credentialFile = p.join(
              callerDirectory.path,
              'serve.credential',
            );
            cli.debugWriteServePortFile(portFile, 8787);
            cli.debugWriteServeCredentialFile(credentialFile, 'a' * 43);
            expect(File(portFile).readAsStringSync(), '8787');
            expect(
              File(credentialFile).readAsStringSync(),
              'Authorization: Bearer ${'a' * 43}\n',
            );
            expect(_permissions(portFile), 0x180);
            expect(_permissions(credentialFile), 0x180);
            expect(_permissions(callerDirectory.path), 0x1ed);
            expect(
              callerDirectory.listSync().where(
                (entity) => entity.path.endsWith('.tmp'),
              ),
              isEmpty,
            );

            File(portFile).deleteSync();
            Link(portFile).createSync(outside.path);
            expect(
              () => cli.debugWriteServePortFile(portFile, 9999),
              throwsA(isA<ScoutCliException>()),
            );
            File(credentialFile).deleteSync();
            Link(credentialFile).createSync(outside.path);
            expect(
              () => cli.debugWriteServeCredentialFile(credentialFile, 'b' * 43),
              throwsA(isA<ScoutCliException>()),
            );
            expect(outside.readAsStringSync(), 'untouched');
          });
        },
      );
    },
    skip: Platform.isWindows ? 'POSIX storage contract' : false,
  );
}

int _permissions(String path) => FileStat.statSync(path).mode & 0x1ff;

Future<void> _withStorageTempCwd(
  Future<void> Function(Directory temp) body,
) async {
  final previous = Directory.current;
  final temp = await Directory.systemTemp.createTemp('scout_storage_');
  try {
    Directory.current = temp;
    await body(temp);
  } finally {
    Directory.current = previous;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}
