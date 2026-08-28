import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('v15 mutation protocol', () {
    test('preflights and sends a complete exactly-once envelope', () async {
      final fake = await _FakeVmService.start();
      addTearDown(fake.close);

      await _withProtocolSession(fake.uri, () async {
        expect(await FlutterScoutCli().run(['tap', 'btn.save']), 0);
      });

      expect(fake.extensionMethods, <String>[
        'ext.flutter_scout.inspect',
        'ext.flutter_scout.tap',
      ]);
      final mutation = fake.mutationParams.single;
      expect(mutation['schemaVersion'], '1');
      expect(mutation['clientProtocolMin'], '15');
      expect(mutation['clientProtocolMax'], '15');
      expect(mutation['runId'], 'test-run');
      expect(mutation['runtimeInstanceId'], 'runtime-a');
      expect(mutation['expectedStateGeneration'], '7');
      expect(mutation['target'], 'btn.save');
      expect(mutation['commandId'], isNotEmpty);
      expect(mutation['idempotencyKey'], isNotEmpty);
      expect(int.parse(mutation['deadlineEpochMs']!), greaterThan(0));
    });

    test('compact output retains every closed-outcome safety dimension', () {
      final compact = FlutterScoutCli().debugCompactActionResult(
        <String, dynamic>{
          'ok': true,
          'schemaVersion': 1,
          'protocolVersion': 15,
          'commandId': 'command-a',
          'runId': 'run-a',
          'runtimeInstanceId': 'runtime-a',
          'stateGeneration': 8,
          'errorCursor': 4,
          'errorsSinceCursor': const <Object?>[],
          'transport': 'ok',
          'dispatch': 'dispatched',
          'observation': 'changed',
          'postcondition': 'postcondition_met',
          'runtimeHealth': 'runtime_clean',
          'stable': false,
          'stability': const <String, Object?>{
            'state': 'never_settling',
            'actionable': false,
            'stoppingReason': 'budget_exhausted_semantics_changing',
            'elapsedMs': 500,
            'budgetMs': 500,
          },
          'idempotencyKey': 'idem-a',
          'expectedStateGeneration': 7,
          'deadlineEpochMs': 123456,
          'beforeStateGeneration': 7,
          'beforeSnapshotId': 'g7:before',
          'afterStateGeneration': 8,
          'afterSnapshotId': 'g8:after',
          'after': const <String, Object?>{
            'screen': 'ConfirmSurface',
            'screenEvidence': <String, Object?>{
              'kind': 'heuristic_inference',
              'source': 'active_surface',
              'scoreKind': 'uncalibrated_heuristic',
            },
            'activeSurface': <String, Object?>{
              'kind': 'dialog',
              'label': 'Confirm',
              'screen': 'ConfirmSurface',
              'source': 'prominentText',
              'heuristicScore': 0.82,
              'scoreKind': 'uncalibrated_heuristic',
            },
          },
        },
      );

      for (final key in const <String>[
        'schemaVersion',
        'protocolVersion',
        'commandId',
        'runId',
        'runtimeInstanceId',
        'stateGeneration',
        'errorCursor',
        'errorsSinceCursor',
        'transport',
        'dispatch',
        'observation',
        'postcondition',
        'runtimeHealth',
        'stable',
        'stability',
        'idempotencyKey',
        'expectedStateGeneration',
        'deadlineEpochMs',
        'beforeStateGeneration',
        'beforeSnapshotId',
        'afterStateGeneration',
        'afterSnapshotId',
      ]) {
        expect(compact, contains(key), reason: '$key was compacted away');
      }
      expect(
        compact['activeSurface'],
        allOf(
          containsPair('source', 'prominentText'),
          containsPair('heuristicScore', 0.82),
          containsPair('scoreKind', 'uncalibrated_heuristic'),
        ),
      );
      expect(
        compact['screenEvidence'],
        containsPair('kind', 'heuristic_inference'),
      );
    });

    test('timeout reconciliation reuses the exact mutation identity', () async {
      final fake = await _FakeVmService.start(dropFirstMutationResponse: true);
      addTearDown(fake.close);

      await _withProtocolSession(fake.uri, () async {
        expect(
          await FlutterScoutCli().run(['tap', 'btn.save', '--wait-ms=-14980']),
          0,
        );
      });

      expect(fake.mutationParams, hasLength(2));
      expect(fake.mutationParams[1], fake.mutationParams[0]);
    });

    test(
      'caller key replays across CLI processes and conflicts abstain offline',
      () async {
        final fake = await _FakeVmService.start();
        addTearDown(fake.close);

        await _withProtocolSession(fake.uri, () async {
          const key = 'save-order-42';
          expect(
            await FlutterScoutCli().run([
              '--idempotency-key',
              key,
              'tap',
              'btn.save',
              '--wait-ms=-14980',
            ]),
            0,
          );
          File(p.join('.flutter_scout', 'vm_uri.txt')).deleteSync();
          expect(
            await FlutterScoutCli().run([
              'tap',
              'btn.save',
              '--idempotency-key=$key',
              '--wait-ms=-14980',
            ]),
            0,
          );
          expect(
            await FlutterScoutCli().run([
              '--idempotency-key',
              key,
              'tap',
              'btn.delete',
              '--wait-ms=-14980',
            ]),
            1,
          );
        });

        expect(fake.dispatchCount, 1);
        expect(fake.mutationParams, hasLength(1));
      },
    );

    test('local mutation receipts replay across CLI processes', () async {
      final fake = await _FakeVmService.start();
      addTearDown(fake.close);
      var localDispatches = 0;

      await _withProtocolSession(fake.uri, () async {
        Future<Map<String, dynamic>> invoke(String value) =>
            FlutterScoutCli().debugDurableLocalMutation(
              idempotencyKey: 'local-reload-scope',
              method: 'process.flutter.reload',
              businessParams: <String, String>{'action': value},
              dispatch: () async {
                localDispatches += 1;
                return <String, dynamic>{
                  'ok': true,
                  'action': value,
                  'dispatch': 'dispatched',
                  'timings': _fakeHelperTimings(totalMs: 2, mutating: true),
                };
              },
            );

        final first = await invoke('reload');
        final replay = await invoke('reload');
        final conflict = await invoke('restart');
        expect(first['ok'], isTrue);
        expect((replay['idempotency'] as Map)['status'], 'replayed');
        final firstPhases = ((first['timings'] as Map)['phases'] as Map);
        final replayPhases = ((replay['timings'] as Map)['phases'] as Map);
        expect(firstPhases.keys.toList(), const <String>[
          'connect',
          'snapshot',
          'match',
          'dispatch',
          'settle',
          'delta',
          'logs',
          'serialize',
        ]);
        expect(replayPhases, firstPhases);
        expect(conflict['dispatch'], 'not_dispatched');
        expect((conflict['error'] as Map)['code'], 'idempotency_conflict');
      });

      expect(localDispatches, 1);
      expect(fake.dispatchCount, 0);
    });

    test(
      'local mutation legacy stable fails closed without semantic stability',
      () async {
        final fake = await _FakeVmService.start();
        addTearDown(fake.close);

        await _withProtocolSession(fake.uri, () async {
          final unavailable = await FlutterScoutCli().debugDurableLocalMutation(
            idempotencyKey: 'local-stability-unavailable',
            method: 'process.flutter.reload',
            businessParams: const <String, String>{'action': 'reload'},
            dispatch: () async => <String, dynamic>{
              'ok': true,
              'dispatch': 'dispatched',
              'stable': true,
              'timings': _fakeHelperTimings(totalMs: 2, mutating: true),
            },
          );

          expect(unavailable['ok'], isTrue);
          expect(unavailable['stable'], isFalse);
          expect(
            unavailable['stability'],
            allOf(
              containsPair('state', 'observation_unavailable'),
              containsPair('actionable', isFalse),
            ),
          );

          final observed = await FlutterScoutCli().debugDurableLocalMutation(
            idempotencyKey: 'local-stability-observed',
            method: 'process.flutter.reload',
            businessParams: const <String, String>{'action': 'reload'},
            dispatch: () async => <String, dynamic>{
              'ok': true,
              'dispatch': 'dispatched',
              'stable': true,
              'stability': const <String, Object?>{
                'state': 'stable',
                'actionable': true,
              },
              'timings': _fakeHelperTimings(totalMs: 2, mutating: true),
            },
          );

          expect(observed['stable'], isTrue);
        });

        expect(fake.dispatchCount, 0);
      },
    );

    test(
      'large known mutation outcomes are committed but marked nonreplayable',
      () async {
        final fake = await _FakeVmService.start();
        addTearDown(fake.close);

        await _withProtocolSession(fake.uri, () async {
          final result = await FlutterScoutCli().debugDurableLocalMutation(
            idempotencyKey: 'large-known-outcome',
            method: 'process.flutter.reload',
            businessParams: const <String, String>{'action': 'reload'},
            dispatch: () async => <String, dynamic>{
              'ok': true,
              'dispatch': 'dispatched',
              'evidence': 'x' * (129 * 1024),
              'timings': _fakeHelperTimings(totalMs: 2, mutating: true),
            },
          );

          final idempotency = result['idempotency'] as Map;
          expect(result['ok'], isTrue);
          expect(result['dispatch'], 'dispatched');
          expect(idempotency['status'], 'committed_nonreplayable');
          expect(idempotency['replayability'], 'unavailable');
          expect(
            idempotency['replayUnavailableReason'],
            'bounded_outcome_storage_limit',
          );
          final compact = FlutterScoutCli().debugCompactActionResult(result);
          expect(
            (compact['idempotency'] as Map)['status'],
            'committed_nonreplayable',
          );

          final registry =
              jsonDecode(
                    File(
                      p.join('.flutter_scout', 'idempotency', 'registry.json'),
                    ).readAsStringSync(),
                  )
                  as Map<String, dynamic>;
          final receipt =
              (registry['records'] as Map<String, dynamic>).values.single
                  as Map<String, dynamic>;
          expect(receipt['phase'], 'outcome_unknown');
          expect(
            receipt['outcomeUnavailableReason'],
            'bounded_outcome_storage_limit',
          );
        });
      },
    );

    test('unknown local mutation receipt never redispatches', () async {
      final fake = await _FakeVmService.start();
      addTearDown(fake.close);
      var localDispatches = 0;

      await _withProtocolSession(fake.uri, () async {
        Future<Map<String, dynamic>> invoke() =>
            FlutterScoutCli().debugDurableLocalMutation(
              idempotencyKey: 'local-unknown-scope',
              method: 'process.simctl.openurl',
              businessParams: const <String, String>{'url': 'example://safe'},
              dispatch: () async {
                localDispatches += 1;
                throw const FileSystemException('transport lost');
              },
            );

        final first = await invoke();
        final retry = await invoke();
        expect(first['dispatch'], 'dispatch_outcome_unknown');
        expect((first['idempotency'] as Map)['status'], 'outcome_unknown');
        expect(retry['dispatch'], 'dispatch_outcome_unknown');
      });

      expect(localDispatches, 1);
      expect(fake.dispatchCount, 0);
    });

    test(
      'uncertain process retry reconciles the same helper mutation once',
      () async {
        final fake = await _FakeVmService.start(dropAllMutationResponses: true);
        addTearDown(fake.close);

        await _withProtocolSession(fake.uri, () async {
          const key = 'timeout-process-retry';
          expect(
            await FlutterScoutCli().run([
              '--idempotency-key',
              key,
              'tap',
              'btn.save',
              '--wait-ms=-14980',
            ]),
            1,
          );
          fake.dropAllMutationResponses = false;
          expect(
            await FlutterScoutCli().run([
              '--idempotency-key',
              key,
              'tap',
              'btn.save',
              '--wait-ms=-14980',
            ]),
            0,
          );
        });

        expect(fake.dispatchCount, 1);
        expect(fake.mutationParams, hasLength(3));
        expect(
          fake.mutationParams.map((params) => params['idempotencyKey']).toSet(),
          {'timeout-process-retry'},
        );
        expect(fake.mutationParams[1], fake.mutationParams[0]);
        expect(fake.mutationParams[2], fake.mutationParams[0]);
      },
    );

    for (final connectionFailure in <String>['missing_uri', 'connect_failed']) {
      test(
        'reserved cross-process receipt stays unknown when $connectionFailure',
        () async {
          final fake = await _FakeVmService.start(
            dropAllMutationResponses: true,
          );
          addTearDown(fake.close);

          await _withProtocolSession(fake.uri, () async {
            const key = 'reserved-before-reconnect';
            expect(
              await FlutterScoutCli().run([
                '--idempotency-key',
                key,
                'tap',
                'btn.save',
                '--wait-ms=-14980',
              ]),
              1,
            );
            final registryFile = File(
              p.join('.flutter_scout', 'idempotency', 'registry.json'),
            );
            final registry =
                jsonDecode(registryFile.readAsStringSync())
                    as Map<String, dynamic>;
            final receipt =
                (registry['records'] as Map<String, dynamic>).values.single
                    as Map<String, dynamic>;
            receipt
              ..['phase'] = 'reserved'
              ..remove('outcome')
              ..remove('outcomeUnavailableReason');
            registryFile.writeAsStringSync(jsonEncode(registry));
            if (!Platform.isWindows) {
              Process.runSync('chmod', <String>['600', registryFile.path]);
            }

            final vmUriFile = File(p.join('.flutter_scout', 'vm_uri.txt'));
            if (connectionFailure == 'missing_uri') {
              vmUriFile.deleteSync();
            } else {
              vmUriFile.writeAsStringSync('ws://127.0.0.1:1/ws');
            }
            expect(
              await FlutterScoutCli().run([
                '--idempotency-key',
                key,
                'tap',
                'btn.save',
                '--wait-ms=-14980',
              ]),
              1,
            );
            final events = File(
              p.join('.flutter_scout', 'events.jsonl'),
            ).readAsLinesSync().map(jsonDecode).whereType<Map>();
            final action = events.lastWhere(
              (event) => event['type'] == 'action_result',
            );
            expect(action['dispatch'], 'dispatch_outcome_unknown');
            expect(
              (action['error'] as Map)['code'],
              'idempotency_reconciliation_unavailable',
            );
          });

          expect(fake.dispatchCount, 1);
          expect(fake.mutationParams, hasLength(2));
        },
      );
    }

    test(
      'corrupt durable registry fails unknown and never dispatches',
      () async {
        final fake = await _FakeVmService.start();
        addTearDown(fake.close);

        await _withProtocolSession(fake.uri, () async {
          final directory = Directory(p.join('.flutter_scout', 'idempotency'))
            ..createSync(recursive: true);
          final registry = File(p.join(directory.path, 'registry.json'))
            ..writeAsStringSync('{not-json');
          if (!Platform.isWindows) {
            Process.runSync('chmod', <String>['600', registry.path]);
          }
          expect(
            await FlutterScoutCli().run([
              '--idempotency-key',
              'possibly-prior-key',
              'tap',
              'btn.save',
            ]),
            1,
          );
          final events = File(
            p.join('.flutter_scout', 'events.jsonl'),
          ).readAsLinesSync().map(jsonDecode).whereType<Map>();
          final action = events.lastWhere(
            (event) => event['type'] == 'action_result',
          );
          expect(action['dispatch'], 'dispatch_outcome_unknown');
          expect(
            (action['error'] as Map)['code'],
            'idempotency_registry_integrity_unknown',
          );
        });

        expect(fake.dispatchCount, 0);
        expect(fake.mutationParams, isEmpty);
      },
    );

    test('uncertain receipt abstains after runtime replacement', () async {
      final fake = await _FakeVmService.start(dropAllMutationResponses: true);
      addTearDown(fake.close);

      await _withProtocolSession(fake.uri, () async {
        const key = 'runtime-replacement';
        expect(
          await FlutterScoutCli().run([
            '--idempotency-key',
            key,
            'tap',
            'btn.save',
            '--wait-ms=-14980',
          ]),
          1,
        );
        fake
          ..dropAllMutationResponses = false
          ..replaceRuntime('runtime-b');
        expect(
          await FlutterScoutCli().run([
            '--idempotency-key',
            key,
            'tap',
            'btn.save',
            '--wait-ms=-14980',
          ]),
          1,
        );
        final events = File(
          p.join('.flutter_scout', 'events.jsonl'),
        ).readAsLinesSync().map(jsonDecode).whereType<Map<String, dynamic>>();
        final action = events.lastWhere(
          (event) => event['type'] == 'action_result',
        );
        expect(action['dispatch'], 'dispatch_outcome_unknown');
        expect(
          (action['error'] as Map<String, dynamic>)['code'],
          'idempotency_runtime_replaced',
        );
      });

      // Two requests are the first call plus its exact same-key timeout
      // reconciliation. No request is sent to runtime-b.
      expect(fake.mutationParams, hasLength(2));
      expect(fake.dispatchCount, 1);
    });

    test(
      'durable receipt persists no raw key, target, or input secret',
      () async {
        final fake = await _FakeVmService.start();
        addTearDown(fake.close);

        await _withProtocolSession(fake.uri, () async {
          const key = 'private-input-operation';
          const target = 'field.private_password';
          const secret = 'S3cret-value-never-persist';
          expect(
            await FlutterScoutCli().run([
              'input',
              '--idempotency-key',
              key,
              '--target',
              target,
              secret,
              '--expect-timeout=1',
            ]),
            0,
          );
          final registry = File(
            p.join('.flutter_scout', 'idempotency', 'registry.json'),
          ).readAsStringSync();
          expect(registry, isNot(contains(key)));
          expect(registry, isNot(contains(target)));
          expect(registry, isNot(contains(secret)));
          expect(registry, contains('"businessParametersPersisted": false'));
          expect(registry, contains('BUSINESS_VALUE:'));
          for (final entity in Directory(
            '.flutter_scout',
          ).listSync(recursive: true, followLinks: false)) {
            if (entity is! File || entity.path.endsWith('.lock')) continue;
            String contents;
            try {
              contents = entity.readAsStringSync();
            } on FileSystemException {
              continue;
            }
            expect(
              contents,
              isNot(contains(key)),
              reason: 'raw caller key persisted in ${entity.path}',
            );
          }
          if (!Platform.isWindows) {
            expect(
              File(
                    p.join('.flutter_scout', 'idempotency', 'registry.json'),
                  ).statSync().mode &
                  0x1ff,
              0x180,
            );
          }
        });
      },
    );

    test(
      'authenticated daemon reconnect replays the original outcome',
      () async {
        final fake = await _FakeVmService.start();
        addTearDown(fake.close);

        await _withProtocolSession(fake.uri, () async {
          Future<void> daemonCycle(int cycle) async {
            final portFile = p.join(
              Directory.current.path,
              'serve-$cycle.port',
            );
            final credentialFile = '$portFile.credential';
            final serve = FlutterScoutCli().run([
              'serve',
              '--port-file',
              portFile,
              '--credential-file',
              credentialFile,
              '--request-timeout=5',
            ]);
            await _waitForProtocolFile(portFile);
            await _waitForProtocolFile(credentialFile);
            final port = int.parse(File(portFile).readAsStringSync());
            final authorization = File(
              credentialFile,
            ).readAsStringSync().trim().substring('Authorization: '.length);
            final client = HttpClient();
            try {
              final response = await _postProtocolJson(
                client,
                port,
                '/v1/call',
                authorization,
                <String, Object?>{
                  'method': 'tap',
                  'idempotencyKey': 'daemon-reconnect-save',
                  'args': <String>['btn.save', '--wait-ms=0'],
                },
              );
              expect(response['exitCode'], 0, reason: 'cycle=$cycle');
              await _postProtocolJson(
                client,
                port,
                '/stop',
                authorization,
                const <String, Object?>{},
                emptyBody: true,
              );
            } finally {
              client.close(force: true);
            }
            expect(await serve, 0);
          }

          await daemonCycle(1);
          await daemonCycle(2);
        });

        expect(fake.dispatchCount, 1);
        expect(fake.mutationParams, hasLength(1));
      },
    );

    test(
      'scroll-to caller scope derives replayable keys for both attempts',
      () async {
        final fake = await _FakeVmService.start(scrollToFallback: true);
        addTearDown(fake.close);

        await _withProtocolSession(fake.uri, () async {
          for (var attempt = 0; attempt < 2; attempt++) {
            expect(
              await FlutterScoutCli().run([
                '--idempotency-key',
                'scroll-to-fallback-scope',
                'scroll-to',
                'btn.offscreen',
              ]),
              0,
              reason: 'attempt=$attempt',
            );
          }
        });

        expect(fake.dispatchCount, 2);
        expect(fake.mutationParams, hasLength(2));
        expect(
          fake.mutationParams.map((params) => params['idempotencyKey']).toSet(),
          hasLength(2),
        );
        expect(
          fake.mutationParams.map((params) => params['direction']),
          <Object?>['down', 'up'],
        );
      },
    );

    test('batch and replay derive stable, distinct per-step keys', () async {
      final fake = await _FakeVmService.start();
      addTearDown(fake.close);

      await _withProtocolSession(fake.uri, () async {
        const batchScript =
            'tap btn.first --wait-ms=0; '
            'tap btn.second --wait-ms=0';
        for (var attempt = 0; attempt < 2; attempt++) {
          expect(
            await FlutterScoutCli().run([
              '--idempotency-key',
              'batch-flow-scope',
              'batch',
              batchScript,
            ]),
            0,
          );
        }
        expect(fake.dispatchCount, 2);
        final batchKeys = fake.mutationParams
            .map((params) => params['idempotencyKey'])
            .toSet();
        expect(batchKeys, hasLength(2));

        final replayFile = File(p.join(Directory.current.path, 'replay.json'))
          ..writeAsStringSync(
            jsonEncode(<Object?>[
              <String, Object?>{
                'cmd': 'tap',
                'target': 'btn.replay_first',
                'waitMs': '0',
              },
              <String, Object?>{
                'cmd': 'tap',
                'target': 'btn.replay_second',
                'waitMs': '0',
              },
            ]),
          );
        for (var attempt = 0; attempt < 2; attempt++) {
          expect(
            await FlutterScoutCli().run([
              '--idempotency-key',
              'replay-flow-scope',
              'replay',
              replayFile.path,
            ]),
            0,
          );
        }
        expect(fake.dispatchCount, 4);
        final allKeys = fake.mutationParams
            .map((params) => params['idempotencyKey'])
            .toSet();
        expect(allKeys, hasLength(4));
      });
    });

    test(
      'bounded CLI registry fails closed instead of evicting receipts',
      () async {
        final fake = await _FakeVmService.start();
        addTearDown(fake.close);

        await _withProtocolSession(fake.uri, () async {
          final records = <String, Object?>{
            for (var index = 0; index < 512; index++)
              crypto.sha256
                  .convert(utf8.encode('old-key-$index'))
                  .toString(): <String, Object?>{
                'phase': 'tombstone',
                'businessFingerprint': crypto.sha256
                    .convert(utf8.encode('old-request-$index'))
                    .toString(),
              },
          };
          final directory = Directory(p.join('.flutter_scout', 'idempotency'))
            ..createSync(recursive: true);
          final registry = File(p.join(directory.path, 'registry.json'))
            ..writeAsStringSync(
              jsonEncode(<String, Object?>{
                'schemaVersion': 1,
                'records': records,
              }),
            );
          if (!Platform.isWindows) {
            Process.runSync('chmod', <String>['600', registry.path]);
          }

          expect(
            await FlutterScoutCli().run([
              '--idempotency-key',
              'new-key-after-capacity',
              'tap',
              'btn.save',
              '--wait-ms=-14980',
            ]),
            1,
          );
          expect(fake.dispatchCount, 0);
        });
      },
    );

    test('CLI pruning keeps a no-redispatch tombstone', () async {
      final fake = await _FakeVmService.start();
      addTearDown(fake.close);

      await _withProtocolSession(fake.uri, () async {
        final keys = <String>[];
        for (var index = 0; index < 65; index++) {
          final key = 'prune-receipt-$index';
          keys.add(key);
          expect(
            await FlutterScoutCli().run([
              '--idempotency-key',
              key,
              'tap',
              'btn.save',
              '--wait-ms=-14980',
            ]),
            0,
            reason: 'index=$index',
          );
        }
        final registry =
            jsonDecode(
                  File(
                    p.join('.flutter_scout', 'idempotency', 'registry.json'),
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        final records = registry['records'] as Map<String, dynamic>;
        expect(
          records.values.where(
            (value) => (value as Map)['phase'] == 'completed',
          ),
          hasLength(64),
        );
        final tombstoneEntry = records.entries.singleWhere(
          (entry) => (entry.value as Map)['phase'] == 'tombstone',
        );
        final tombstonedKey = keys.singleWhere(
          (key) =>
              crypto.sha256.convert(utf8.encode(key)).toString() ==
              tombstoneEntry.key,
        );
        expect(
          await FlutterScoutCli().run([
            '--idempotency-key',
            tombstonedKey,
            'tap',
            'btn.save',
            '--wait-ms=-14980',
          ]),
          1,
        );
        expect(fake.dispatchCount, 65);
      });
    });

    test(
      'unreconciled timeout is unknown and never gets a fresh key',
      () async {
        final fake = await _FakeVmService.start(dropAllMutationResponses: true);
        addTearDown(fake.close);

        await _withProtocolSession(fake.uri, () async {
          expect(
            await FlutterScoutCli().run([
              'tap',
              'btn.save',
              '--wait-ms=-14980',
            ]),
            1,
          );
          final events = File(
            p.join('.flutter_scout', 'events.jsonl'),
          ).readAsLinesSync().map(jsonDecode).whereType<Map<String, dynamic>>();
          final action = events.lastWhere(
            (event) => event['type'] == 'action_result',
          );
          expect(action['transport'], 'timeout');
          expect(action['dispatch'], 'dispatch_outcome_unknown');
          expect(action['observation'], 'observation_unavailable');
          expect(action['runId'], 'test-run');
          expect(action['runtimeInstanceId'], 'runtime-a');
          expect(action['stateGeneration'], 7);
          expect(action['logCursor'], isA<int>());
          expect(action['stable'], isFalse);
          expect(
            (action['stability'] as Map<String, dynamic>)['state'],
            'runtime_lost',
          );
          expect(
            (action['stability'] as Map<String, dynamic>)['actionable'],
            isFalse,
          );
          expect(action['commandId'], isNotEmpty);
          expect(action, isNot(contains('idempotencyKey')));
          expect(
            action['idempotencyKeyDigest'],
            matches(RegExp(r'^[a-f0-9]{64}$')),
          );
          expect(
            action['evidence'],
            allOf(
              containsPair('status', 'committed'),
              containsPair('eventJournal', 'committed'),
            ),
          );
        });

        expect(fake.mutationParams, hasLength(2));
        expect(fake.mutationParams[1], fake.mutationParams[0]);
      },
    );

    test('incompatible helper is rejected before any mutation', () async {
      final fake = await _FakeVmService.start(incompatible: true);
      addTearDown(fake.close);

      await _withProtocolSession(fake.uri, () async {
        expect(await FlutterScoutCli().run(['tap', 'btn.save']), 1);
      });

      expect(fake.extensionMethods, <String>['ext.flutter_scout.inspect']);
      expect(fake.mutationParams, isEmpty);
    });

    for (final protocol in <int>[14, 16]) {
      test('protocol $protocol is rejected before any mutation', () async {
        final fake = await _FakeVmService.start(helperProtocol: protocol);
        addTearDown(fake.close);

        await _withProtocolSession(fake.uri, () async {
          expect(await FlutterScoutCli().run(['tap', 'btn.save']), 1);
        });

        expect(fake.extensionMethods, <String>['ext.flutter_scout.inspect']);
        expect(fake.mutationParams, isEmpty);
      });
    }

    test('missing safety capability is rejected before mutation', () async {
      final fake = await _FakeVmService.start(
        omittedCapability: 'sourceRedaction',
      );
      addTearDown(fake.close);

      await _withProtocolSession(fake.uri, () async {
        expect(await FlutterScoutCli().run(['tap', 'btn.save']), 1);
      });

      expect(fake.extensionMethods, <String>['ext.flutter_scout.inspect']);
      expect(fake.mutationParams, isEmpty);
    });
  });
}

Future<void> _waitForProtocolFile(String path) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (File(path).existsSync() && File(path).lengthSync() > 0) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('Timed out waiting for $path');
}

Future<Map<String, dynamic>> _postProtocolJson(
  HttpClient client,
  int port,
  String path,
  String authorization,
  Map<String, Object?> body, {
  bool emptyBody = false,
}) async {
  final request = await client.postUrl(
    Uri.parse('http://127.0.0.1:$port$path'),
  );
  request.headers.set(HttpHeaders.authorizationHeader, authorization);
  if (!emptyBody) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  final response = await request.close();
  final text = await utf8.decoder.bind(response).join();
  final decoded = jsonDecode(text);
  return Map<String, dynamic>.from(decoded as Map);
}

Future<void> _withProtocolSession(
  Uri vmUri,
  Future<void> Function() body,
) async {
  final previous = Directory.current;
  final temporary = await Directory.systemTemp.createTemp(
    'flutter_scout_protocol_',
  );
  try {
    Directory.current = temporary;
    final session = Directory(p.join(temporary.path, '.flutter_scout'))
      ..createSync();
    File(p.join(session.path, 'vm_uri.txt')).writeAsStringSync('$vmUri');
    File(p.join(session.path, 'session_meta.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'mode': 'attach_only',
        'state': 'ready',
        'runId': 'test-run',
        'vmServiceUri': '$vmUri',
      }),
    );
    await body();
  } finally {
    Directory.current = previous;
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  }
}

class _FakeVmService {
  _FakeVmService._(
    this._server,
    this.incompatible,
    this.dropFirstMutationResponse,
    this.dropAllMutationResponses,
    this.helperProtocol,
    this.omittedCapability,
    this.scrollToFallback,
  );

  final HttpServer _server;
  final bool incompatible;
  bool dropFirstMutationResponse;
  bool dropAllMutationResponses;
  final int helperProtocol;
  final String? omittedCapability;
  final bool scrollToFallback;
  final List<WebSocket> _sockets = <WebSocket>[];
  final List<String> extensionMethods = <String>[];
  final List<Map<String, dynamic>> mutationParams = <Map<String, dynamic>>[];
  final Map<String, Map<String, Object?>> _mutationOutcomes =
      <String, Map<String, Object?>>{};
  String runtimeInstanceId = 'runtime-a';
  int dispatchCount = 0;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}/ws');

  static Future<_FakeVmService> start({
    bool incompatible = false,
    bool dropFirstMutationResponse = false,
    bool dropAllMutationResponses = false,
    int helperProtocol = 15,
    String? omittedCapability,
    bool scrollToFallback = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeVmService._(
      server,
      incompatible,
      dropFirstMutationResponse,
      dropAllMutationResponses,
      helperProtocol,
      omittedCapability,
      scrollToFallback,
    );
    unawaited(fake._serve());
    return fake;
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        continue;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      socket.listen((Object? data) => _handle(socket, data));
    }
  }

  void _handle(WebSocket socket, Object? data) {
    final request = jsonDecode(data! as String) as Map<String, dynamic>;
    final id = request['id'];
    final method = request['method']!.toString();
    final params = request['params'] is Map
        ? Map<String, dynamic>.from(request['params'] as Map)
        : <String, dynamic>{};
    if (method == 'getVM') {
      _reply(socket, id, <String, Object?>{
        'type': 'VM',
        'name': 'vm',
        'architectureBits': 64,
        'hostCPU': 'test',
        'operatingSystem': 'test',
        'targetCPU': 'test',
        'version': 'test',
        'pid': 1,
        'startTime': 0,
        'isolates': <Object?>[
          <String, Object?>{
            'type': '@Isolate',
            'id': 'isolates/1',
            'name': 'main',
            'number': '1',
            'isSystemIsolate': false,
          },
        ],
      });
      return;
    }
    if (method.startsWith('ext.flutter_scout.')) {
      extensionMethods.add(method);
      if (method != 'ext.flutter_scout.inspect') {
        mutationParams.add(params);
        final key = params['idempotencyKey']?.toString() ?? '';
        final payload = _mutationOutcomes.putIfAbsent(key, () {
          dispatchCount += 1;
          return _mutation(method, params['commandId']?.toString(), params);
        });
        if (dropAllMutationResponses ||
            (dropFirstMutationResponse && mutationParams.length == 1)) {
          return;
        }
        _reply(socket, id, payload);
        return;
      }
      final commandId = params['commandId']?.toString();
      final payload = _preflight(commandId);
      _reply(socket, id, payload);
      return;
    }
    socket.add(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, Object?>{
          'code': -32601,
          'message': 'Unknown method $method',
        },
      }),
    );
  }

  Map<String, Object?> _preflight(String? commandId) => <String, Object?>{
    'ok': true,
    'schemaVersion': incompatible ? 0 : 1,
    'protocolVersion': incompatible ? 14 : helperProtocol,
    'minSupportedProtocolVersion': incompatible ? 14 : helperProtocol,
    'maxSupportedProtocolVersion': incompatible ? 14 : helperProtocol,
    'capabilities': _capabilities(),
    'commandId': commandId,
    'runId': 'test-run',
    'runtimeInstanceId': runtimeInstanceId,
    'stateGeneration': 7,
    'stateDigest': List<String>.filled(64, 'a').join(),
    'snapshotId': 'g7:${List<String>.filled(64, 'a').join()}',
    'errorCursor': 3,
    'errorsSinceCursor': const <Object?>[],
    'activeBlockingSignals': const <Object?>[],
    'result': const <String, Object?>{},
    'structuredError': null,
    'timings': _fakeHelperTimings(totalMs: 1, mutating: false),
  };

  Map<String, Object?> _mutation(
    String method,
    String? commandId,
    Map<String, dynamic> params,
  ) {
    final payload = <String, Object?>{
      'ok': true,
      'schemaVersion': 1,
      'protocolVersion': 15,
      'minSupportedProtocolVersion': 15,
      'maxSupportedProtocolVersion': 15,
      'capabilities': _capabilities(),
      'commandId': commandId,
      'runId': params['runId'],
      'runtimeInstanceId': params['runtimeInstanceId'],
      'stateGeneration': 8,
      'result': 'changed',
      'structuredError': null,
      'echo': <String, Object?>{
        if (params['target'] != null) 'target': params['target'],
        if (params['value'] != null) 'value': params['value'],
        if (params['x'] != null) 'x': num.tryParse(params['x'].toString()),
      },
      'activation': const <String, Object?>{
        'dispatched': true,
        'observedChange': true,
      },
      'before': const <String, Object?>{
        'stateGeneration': 7,
        'snapshotId': 'g7:before',
        'screen': 'home',
      },
      'after': const <String, Object?>{
        'stateGeneration': 8,
        'snapshotId': 'g8:after',
        'screen': 'saved',
      },
      'delta': const <String, Object?>{'screenChanged': true},
      'errorCursor': 3,
      'errorsSinceCursor': const <Object?>[],
      'activeBlockingSignals': const <Object?>[],
      'timings': _fakeHelperTimings(totalMs: 2, mutating: true),
    };
    if (scrollToFallback &&
        method == 'ext.flutter_scout.scrollTo' &&
        params['direction'] == 'down') {
      payload
        ..['ok'] = false
        ..['result'] = 'completed_same_state'
        ..['reason'] = 'reached_scroll_end'
        ..['scrollsUsed'] = 3
        ..['error'] = const <String, Object?>{
          'code': 'target_not_reached',
          'message': 'Initial direction reached the bounded scroll end.',
        }
        ..['structuredError'] = const <String, Object?>{
          'code': 'target_not_reached',
          'message': 'Initial direction reached the bounded scroll end.',
        };
    }
    return payload;
  }

  Map<String, bool> _capabilities() => <String, bool>{
    for (final entry in const <String, bool>{
      'typedEnvelopeV1': true,
      'stateGeneration': true,
      'stateDigestSha256': true,
      'strictMutationEnvelope': true,
      'serializedMutations': true,
      'idempotentMutations': true,
      'stableIdempotencyFingerprintV1': true,
      'idempotencyTombstonesV1': true,
      'runtimeErrorCursor': true,
      'heldDragExclusion': true,
      'sourceRedaction': true,
      'phaseTimingsV1': true,
    }.entries)
      if (entry.key != omittedCapability) entry.key: entry.value,
  };

  void replaceRuntime(String value) {
    runtimeInstanceId = value;
    _mutationOutcomes.clear();
  }

  void _reply(WebSocket socket, Object? id, Map<String, Object?> result) {
    _expectAdvertisedPhaseTimings(result);
    socket.add(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      }),
    );
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}

Map<String, Object?> _fakeHelperTimings({
  required int totalMs,
  required bool mutating,
}) => <String, Object?>{
  'totalMs': totalMs,
  'status': 'partial',
  'phases': <String, Object?>{
    for (final phase in const <String>['connect', 'logs'])
      phase: const <String, Object?>{
        'status': 'unavailable',
        'elapsedMs': null,
        'owner': 'cli',
        'reason': 'measured_at_cli_boundary',
      },
    'snapshot': const <String, Object?>{
      'status': 'measured',
      'elapsedMs': 0,
      'owner': 'helper',
    },
    for (final phase in const <String>['match', 'dispatch', 'settle', 'delta'])
      phase: mutating
          ? const <String, Object?>{
              'status': 'measured',
              'elapsedMs': 0,
              'owner': 'helper',
            }
          : const <String, Object?>{
              'status': 'unavailable',
              'elapsedMs': null,
              'owner': 'helper',
              'reason': 'not_applicable_for_read:inspect',
            },
    'serialize': const <String, Object?>{
      'status': 'measured',
      'elapsedMs': 0,
      'owner': 'helper',
    },
  },
};

void _expectAdvertisedPhaseTimings(Map<String, Object?> result) {
  final capabilities = result['capabilities'];
  if (capabilities is! Map || capabilities['phaseTimingsV1'] != true) return;
  const phaseNames = <String>[
    'connect',
    'snapshot',
    'match',
    'dispatch',
    'settle',
    'delta',
    'logs',
    'serialize',
  ];
  final timings = result['timings'];
  expect(timings, isA<Map>());
  final phases = (timings! as Map)['phases'];
  expect(phases, isA<Map>());
  expect((phases! as Map).keys.toSet(), phaseNames.toSet());
  for (final phaseName in phaseNames) {
    final record = phases[phaseName];
    expect(record, isA<Map>(), reason: phaseName);
    if ((record as Map)['status'] == 'measured') {
      expect(record['elapsedMs'], isA<int>(), reason: phaseName);
      expect(record['elapsedMs'] as int, greaterThanOrEqualTo(0));
    } else {
      expect(record['status'], 'unavailable', reason: phaseName);
      expect(record['elapsedMs'], isNull, reason: phaseName);
      expect(record['reason'], isA<String>(), reason: phaseName);
      expect((record['reason'] as String).trim(), isNotEmpty);
    }
  }
}
