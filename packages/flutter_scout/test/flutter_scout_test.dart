import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter_scout/flutter_scout.dart';
import 'package:test/test.dart';

void main() {
  test('CLI can be constructed', () {
    expect(FlutterScoutCli(), isA<FlutterScoutCli>());
  });

  group('attach run identity recovery', () {
    test('recovers a verified helper from the prior Scout launch', () {
      final recovered = FlutterScoutCli().debugReconcileAttachRunIdentity(
        previousMeta: const <String, Object?>{
          'mode': 'scout_owned_flutter_run',
          'runId': '20260824125921505783-3807',
          'device': 'ipad-sim',
        },
        helperRunId: '20260824125921505783-3807',
        runtimeInstanceId: 'runtime-verified',
        requestedDevice: 'ipad-sim',
      );

      expect(recovered, isNotNull);
      expect(recovered!['runId'], '20260824125921505783-3807');
      expect(recovered['runtimeInstanceId'], 'runtime-verified');
    });

    test('refuses a different helper run before any mutation can dispatch', () {
      final recovered = FlutterScoutCli().debugReconcileAttachRunIdentity(
        previousMeta: const <String, Object?>{
          'mode': 'scout_owned_flutter_run',
          'runId': 'launch-run',
          'device': 'ipad-sim',
        },
        helperRunId: 'unrelated-local-run',
        runtimeInstanceId: 'runtime-other',
        requestedDevice: 'ipad-sim',
      );

      expect(recovered, isNull);
    });

    test('refuses recovery across explicitly different devices', () {
      final recovered = FlutterScoutCli().debugReconcileAttachRunIdentity(
        previousMeta: const <String, Object?>{
          'mode': 'scout_owned_flutter_run',
          'runId': 'launch-run',
          'device': 'ipad-sim-a',
        },
        helperRunId: 'launch-run',
        runtimeInstanceId: 'runtime-verified',
        requestedDevice: 'ipad-sim-b',
      );

      expect(recovered, isNull);
    });
  });

  group('dedupeVmStdoutEcho', () {
    test('collapses the Flutter tool and VM copies of one app line', () {
      final lines = FlutterScoutCli.dedupeVmStdoutEcho([
        '[2026-08-19T04:00:00.000Z] [FLUTTER_STDOUT] flutter: hello',
        '[2026-08-19T12:00:00.000] [VM_STDOUT] flutter: hello',
      ]);

      expect(lines, [
        '[2026-08-19T04:00:00.000Z] [FLUTTER_STDOUT] flutter: hello',
      ]);
    });

    test('keeps the continuation lines of a multi-line message', () {
      // The regression this guards: the header line survived while the wrapped
      // body was dropped, so `logs --contains` could not find an entry that was
      // plainly present in the log file.
      final lines = FlutterScoutCli.dedupeVmStdoutEcho([
        '[2026-08-19T04:00:00.000Z] [FLUTTER_STDOUT] flutter: TAG => {',
        '  body: first line',
        '  body: second line',
        '}',
        '[2026-08-19T12:00:00.000] [VM_STDOUT] flutter: TAG => {',
        '  body: first line',
        '  body: second line',
        '}',
      ]);

      expect(lines.first, contains('TAG => {'));
      expect(lines.where((line) => line.contains('TAG => {')), hasLength(1));
      expect(lines.where((line) => line == '  body: first line'), hasLength(2));
    });

    test('keeps a line the app really logged twice', () {
      final lines = FlutterScoutCli.dedupeVmStdoutEcho([
        '[t] [FLUTTER_STDOUT] flutter: tick',
        '[t] [FLUTTER_STDOUT] flutter: tick',
        '[t] [VM_STDOUT] flutter: tick',
        '[t] [VM_STDOUT] flutter: tick',
      ]);

      expect(lines, hasLength(2));
      expect(lines.every((line) => line.contains('FLUTTER_STDOUT')), isTrue);
    });

    test('leaves untagged and unmatched lines alone', () {
      const input = [
        'Launching lib/main.dart on macOS in debug mode...',
        '[t] [VM_STDOUT] flutter: only from the VM',
      ];

      expect(FlutterScoutCli.dedupeVmStdoutEcho(input), input);
    });
  });

  group('isNonRuntimeDartPath', () {
    test('skips test sources that a running app never loads', () {
      expect(
        FlutterScoutCli.isNonRuntimeDartPath('test/widget_test.dart'),
        isTrue,
      );
      expect(
        FlutterScoutCli.isNonRuntimeDartPath('packages/app/test/a/b_test.dart'),
        isTrue,
      );
      expect(
        FlutterScoutCli.isNonRuntimeDartPath('integration_test/app_test.dart'),
        isTrue,
      );
    });

    test('keeps real app sources in the verification set', () {
      expect(FlutterScoutCli.isNonRuntimeDartPath('lib/main.dart'), isFalse);
      expect(
        FlutterScoutCli.isNonRuntimeDartPath('lib/src/latest_widget.dart'),
        isFalse,
      );
      // "test" only counts as a directory segment, never as a substring.
      expect(
        FlutterScoutCli.isNonRuntimeDartPath('lib/testing_tools.dart'),
        isFalse,
      );
    });
  });

  group('parseSimctlDevices', () {
    const payload = '''
{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
      {"udid": "AAAA-OLD", "name": "iPad mini (A17 Pro)", "state": "Shutdown", "isAvailable": true}
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
      {"udid": "BBBB-BOOTED", "name": "iPad mini (A17 Pro)", "state": "Booted", "isAvailable": true},
      {"udid": "CCCC-UNAVAIL", "name": "iPhone 16", "state": "Shutdown", "isAvailable": false}
    ],
    "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
      {"udid": "DDDD-WATCH", "name": "Apple Watch", "state": "Shutdown", "isAvailable": true}
    ]
  }
}''';

    test('matches by udid and reports the runtime platform', () {
      final match = FlutterScoutCli.parseSimctlDevices(payload, 'AAAA-OLD');
      expect(match, isNotNull);
      expect(match!['id'], 'AAAA-OLD');
      expect(match['name'], 'iPad mini (A17 Pro)');
      expect(match['platform'], 'ios');
    });

    test('prefers a booted device when a name matches multiple runtimes', () {
      final match = FlutterScoutCli.parseSimctlDevices(
        payload,
        'iPad mini (A17 Pro)',
      );
      expect(match, isNotNull);
      expect(match!['id'], 'BBBB-BOOTED');
    });

    test('derives non-iOS platforms from the runtime key', () {
      final match = FlutterScoutCli.parseSimctlDevices(payload, 'DDDD-WATCH');
      expect(match!['platform'], 'watchos');
    });

    test('skips unavailable devices', () {
      expect(
        FlutterScoutCli.parseSimctlDevices(payload, 'CCCC-UNAVAIL'),
        isNull,
      );
    });

    test('returns null for an unknown target', () {
      expect(FlutterScoutCli.parseSimctlDevices(payload, 'nope'), isNull);
    });

    test('returns null for malformed payloads', () {
      expect(FlutterScoutCli.parseSimctlDevices('not json', 'x'), isNull);
      expect(FlutterScoutCli.parseSimctlDevices('[]', 'x'), isNull);
    });
  });

  group('wellKnownDeviceName', () {
    test('resolves fixed desktop and web ids', () {
      expect(FlutterScoutCli.wellKnownDeviceName('macos'), 'macOS');
      expect(FlutterScoutCli.wellKnownDeviceName('chrome'), 'Chrome');
      expect(FlutterScoutCli.wellKnownDeviceName('windows'), 'Windows');
      expect(FlutterScoutCli.wellKnownDeviceName('web-server'), 'Web Server');
    });

    test('returns null for ids that need real discovery', () {
      expect(FlutterScoutCli.wellKnownDeviceName('macOS'), isNull);
      expect(FlutterScoutCli.wellKnownDeviceName('00008120-001'), isNull);
      expect(FlutterScoutCli.wellKnownDeviceName(''), isNull);
    });
  });

  test('status reports successfully before attach', () async {
    await _withTempCwd(() async {
      final exitCode = await FlutterScoutCli().run(['status']);

      expect(exitCode, 0);
    });
  });

  test(
    'reachable session records when its Scout owner process exited',
    () async {
      await _withTempCwd(() async {
        final sessionDir = Directory('.flutter_scout')..createSync();
        File(
          p.join(sessionDir.path, 'flutter.pid'),
        ).writeAsStringSync('2147483646');
        File(p.join(sessionDir.path, 'session_meta.json')).writeAsStringSync(
          jsonEncode({
            'mode': 'scout_owned_flutter_run',
            'state': 'ready',
            'pid': 2147483646,
            'name': 'receipt-layout',
          }),
        );

        final cli = FlutterScoutCli();
        expect(
          await cli.debugReconcileReachableSessionOwnership(
            'ws://127.0.0.1:1/test/ws',
          ),
          isTrue,
        );

        final meta =
            jsonDecode(
                  File(
                    p.join(sessionDir.path, 'session_meta.json'),
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(meta['mode'], 'attach_only');
        expect(meta['previousMode'], 'scout_owned_flutter_run');
        expect(meta['ownershipLossReason'], 'owner_process_exited');
        expect(meta.containsKey('pid'), isFalse);
        expect(
          File(p.join(sessionDir.path, 'flutter.pid')).existsSync(),
          isFalse,
        );

        final hotUpdate = await cli.debugHotUpdateCapability(
          'ws://127.0.0.1:1/test/ws',
        );
        expect(hotUpdate['ownershipLost'], isTrue);
        expect((hotUpdate['reload'] as Map)['available'], isFalse);
        expect((hotUpdate['reload'] as Map)['preservesState'], isFalse);
        expect(
          (hotUpdate['reload'] as Map)['method'],
          'unavailable_after_owner_process_exit',
        );

        expect(
          await cli.debugReconcileReachableSessionOwnership(
            'ws://127.0.0.1:1/test/ws',
          ),
          isFalse,
          reason: 'subsequent status checks should keep the recorded diagnosis',
        );

        expect(await cli.run(['reload']), 1);
      });
    },
  );

  test('command journal redacts sensitive arguments', () async {
    await _withTempCwd(() async {
      final exitCode = await FlutterScoutCli().run([
        'launch',
        '--dart-define',
        'FEATURE_THEME=midnight-blue',
      ]);
      expect(exitCode, 1);
      final events = File('.flutter_scout/events.jsonl');
      expect(events.existsSync(), isTrue);
      final text = events.readAsStringSync();
      expect(text, contains('[REDACTED]'));
      expect(text, isNot(contains('midnight-blue')));
      final event = jsonDecode(text.trim()) as Map<String, dynamic>;
      expect(event['type'], 'command');
      expect(event['durationMs'], isA<int>());
      expect(event['exitCode'], 1);
    });
  });

  test(
    'record save-last creates a flow from successful session actions',
    () async {
      await _withTempCwd(() async {
        Directory('.flutter_scout').createSync();
        File('.flutter_scout/session.json').writeAsStringSync(
          jsonEncode([
            {'cmd': 'tap', 'target': 'btn.open'},
            {'cmd': 'input', 'target': 'field.name', 'value': 'Template'},
            {'cmd': 'tap', 'target': 'btn.save'},
          ]),
        );

        expect(
          await FlutterScoutCli().run([
            'record',
            'save-last',
            'template-create',
            '--last',
            '2',
            '--feature',
            'forms',
          ]),
          0,
        );
        final flow =
            jsonDecode(
                  File(
                    '.flutter_scout/recordings/forms/template-create.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(flow['source'], 'session_journal');
        expect((flow['steps'] as List), hasLength(2));
        expect((flow['steps'] as List).last['target'], 'btn.save');
      });
    },
  );

  test('launch requires a device id', () async {
    await _withTempCwd(() async {
      final exitCode = await FlutterScoutCli().run(['launch']);

      expect(exitCode, 1);
    });
  });

  test('launch timing never reports a negative build duration', () {
    final timing = FlutterScoutCli().debugLaunchTimingFromLines([
      'Xcode build done.',
      'Running Xcode build...',
    ]);

    expect(timing['buildDurationMs'], isNull);
  });

  test(
    'launch keeps polling through a bounded post-build worker identity race',
    () {
      final cli = FlutterScoutCli();
      final buildDoneAt = DateTime.utc(2026, 8, 24, 14, 14, 15);

      // iOS Simulator can publish the VM-service URI shortly after Xcode says
      // the build is done, while launchd briefly cannot resolve the worker PID.
      // Scout must keep reading its owned log instead of killing that app.
      expect(
        cli.debugShouldAwaitPostBuildVmService(
          now: buildDoneAt.add(const Duration(seconds: 44)),
          buildDoneAt: buildDoneAt,
        ),
        isTrue,
      );
      expect(
        cli.debugShouldAwaitPostBuildVmService(
          now: buildDoneAt.add(const Duration(seconds: 45)),
          buildDoneAt: buildDoneAt,
        ),
        isFalse,
      );
      expect(
        cli.debugShouldAwaitPostBuildVmService(
          now: buildDoneAt.add(const Duration(seconds: 1)),
          buildDoneAt: null,
        ),
        isFalse,
      );
    },
  );

  test('stop succeeds without a stored pid', () async {
    await _withTempCwd(() async {
      final exitCode = await FlutterScoutCli().run(['stop']);

      expect(exitCode, 0);
    });
  });

  test('stop skips unrelated stored pid', () async {
    await _withTempCwd(() async {
      Directory('.flutter_scout').createSync();
      final pidFile = File('.flutter_scout/flutter.pid')
        ..writeAsStringSync(pid.toString());

      final exitCode = await FlutterScoutCli().run(['stop']);

      expect(exitCode, 0);
      expect(pidFile.existsSync(), isFalse);
    });
  });

  test('stop clear-session removes session files', () async {
    await _withTempCwd(() async {
      Directory('.flutter_scout').createSync();
      final vmFile = File('.flutter_scout/vm_uri.txt')
        ..writeAsStringSync('ws://127.0.0.1:1/test/ws');
      final deviceFile = File('.flutter_scout/device.txt')
        ..writeAsStringSync('test-device');
      final sessionFile = File('.flutter_scout/session.json')
        ..writeAsStringSync('[]');

      final exitCode = await FlutterScoutCli().run(['stop', '--clear-session']);

      expect(exitCode, 0);
      expect(vmFile.existsSync(), isFalse);
      expect(deviceFile.existsSync(), isFalse);
      expect(sessionFile.existsSync(), isFalse);
    });
  });

  test('doctor succeeds without a running session', () async {
    await _withTempCwd(() async {
      final exitCode = await FlutterScoutCli().run(['doctor']);

      expect(exitCode, 0);
    });
  });

  test('logs summary succeeds without a log file', () async {
    await _withTempCwd(() async {
      final exitCode = await FlutterScoutCli().run(['logs', '--summary']);

      expect(exitCode, 0);
    });
  });

  test('logs summary rejects malformed utf8 bytes', () async {
    await _withTempCwd(() async {
      Directory('.flutter_scout').createSync();
      File('.flutter_scout/logs.txt').writeAsBytesSync([
        ...utf8.encode(
          '[2026-07-08T13:00:00.000] [VM_LOG] [ScoutSynthetic] '
          'level=0 seq=1 Build Error: Null check operator used on a null value\n',
        ),
        0xff,
        0xfe,
        ...utf8.encode('\n'),
      ]);

      final exitCode = await FlutterScoutCli().run(['logs', '--summary']);

      expect(exitCode, 1);
      expect(
        () => FlutterScoutCli().debugReadScoutLog(),
        throwsA(
          isA<ScoutCliException>().having(
            (error) => error.code,
            'code',
            'runtime_log_corrupt',
          ),
        ),
      );
    });
  });

  test(
    'logs reports attach-only sessions without using stale log files',
    () async {
      await _withTempCwd(() async {
        Directory('.flutter_scout').createSync();
        File(
          '.flutter_scout/session_meta.json',
        ).writeAsStringSync('{"mode":"attach_only"}');
        File('.flutter_scout/logs.txt').writeAsStringSync('stale launch log');

        final exitCode = await FlutterScoutCli().run(['logs', '--summary']);

        expect(exitCode, 0);
      });
    },
  );

  test('logs preserves scout-owned session classification', () async {
    await _withTempCwd(() async {
      Directory('.flutter_scout').createSync();
      File('.flutter_scout/session_meta.json').writeAsStringSync(
        '{"mode":"scout_owned_flutter_run","logFile":".flutter_scout/logs.txt"}',
      );

      final exitCode = await FlutterScoutCli().run(['logs', '--summary']);

      expect(exitCode, 0);
    });
  });

  test('evidence succeeds without an attached session', () async {
    await _withTempCwd(() async {
      final exitCode = await FlutterScoutCli().run(['evidence']);

      expect(exitCode, 0);
      expect(
        Directory('.flutter_scout/evidence')
            .listSync(recursive: true)
            .whereType<File>()
            .any((file) => file.path.endsWith('summary.json')),
        isTrue,
      );
    });
  });

  test('evidence audit mode writes transcript and markdown scaffold', () async {
    await _withTempCwd(() async {
      final sessionDir = Directory('.flutter_scout')..createSync();
      File(p.join(sessionDir.path, 'session.json')).writeAsStringSync(
        jsonEncode([
          {'cmd': 'tap', 'target': 'btn.classroom'},
          {'cmd': 'tap-text', 'text': 'Add Classroom'},
        ]),
      );

      final exitCode = await FlutterScoutCli().run(['evidence', '--audit']);

      expect(exitCode, 0);
      final files = Directory(
        '.flutter_scout/evidence',
      ).listSync(recursive: true).whereType<File>().toList();
      final audit = files.singleWhere((file) => file.path.endsWith('audit.md'));
      final transcript = files.singleWhere(
        (file) => file.path.endsWith('transcript.txt'),
      );
      expect(audit.readAsStringSync(), contains('# Flutter Scout UI/UX Audit'));
      expect(transcript.readAsStringSync(), contains('tap btn.classroom'));
      expect(
        transcript.readAsStringSync(),
        contains('tap-text "Add Classroom"'),
      );
    });
  });

  test('annotation lifecycle commands require exactly one id', () async {
    await _withTempCwd(() async {
      final missingId = await FlutterScoutCli().run(['annotations', 'resolve']);
      final extraId = await FlutterScoutCli().run([
        'annotations',
        'dismiss',
        'ann_001',
        'ann_002',
      ]);

      expect(missingId, 1);
      expect(extraId, 1);
    });
  });

  test('annotation clear accepts only one filter', () async {
    await _withTempCwd(() async {
      final exitCode = await FlutterScoutCli().run([
        'annotations',
        'clear',
        '--resolved',
        '--dismissed',
      ]);

      expect(exitCode, 1);
    });
  });

  test('annotation read commands reject extra arguments', () async {
    await _withTempCwd(() async {
      final exitCode = await FlutterScoutCli().run([
        'annotations',
        'list',
        'extra',
      ]);

      expect(exitCode, 1);
    });
  });

  test('annotation fixed requires exactly one id', () async {
    await _withTempCwd(() async {
      final missingId = await FlutterScoutCli().run(['annotations', 'fixed']);
      final extraId = await FlutterScoutCli().run([
        'annotations',
        'fixed',
        'ann_001',
        'ann_002',
      ]);

      expect(missingId, 1);
      expect(extraId, 1);
    });
  });

  test('annotation wait rejects positional arguments', () async {
    await _withTempCwd(() async {
      final exitCode = await FlutterScoutCli().run([
        'annotations',
        'wait',
        'extra',
      ]);

      expect(exitCode, 1);
    });
  });

  test('annotation wait without a session fails cleanly', () async {
    await _withTempCwd(() async {
      // No vm_uri recorded -> not_attached -> exit 1 without entering the
      // poll loop or hanging.
      final exitCode = await FlutterScoutCli().run([
        'annotations',
        'wait',
        '--timeout',
        '1',
        '--poll',
        '200',
      ]);

      expect(exitCode, 1);
    });
  });

  test('help exits successfully', () async {
    final exitCode = await FlutterScoutCli().run(['--help']);

    expect(exitCode, 0);
  });

  test('command-scoped help does not dispatch the command', () async {
    await _withTempCwd(() async {
      final exitCode = await FlutterScoutCli().run(['reload', '--help']);

      expect(exitCode, 0);
      expect(File('.flutter_scout/events.jsonl').existsSync(), isFalse);
    });
  });

  test('command-scoped help does not require a named session', () async {
    final exitCode = await FlutterScoutCli().run([
      '--app',
      'missing-session',
      'reload',
      '-h',
    ]);

    expect(exitCode, 0);
  });

  test(
    'explore once prints persistent-mode setup without serving forever',
    () async {
      await _withTempCwd(() async {
        final exitCode = await FlutterScoutCli().run(['explore', '--once']);

        expect(exitCode, 0);
      });
    },
  );

  test(
    'attach fails fast against an unresponsive vm service',
    () async {
      // A socket that completes the WebSocket handshake but never answers a
      // VM-service RPC reproduces the dead-DDS state that used to make
      // launch/ensure/attach hang indefinitely at 0% CPU. Attach must give up
      // quickly instead of blocking forever.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      server.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          sockets.add(await WebSocketTransformer.upgrade(request));
          // Intentionally never respond to any RPC.
        } else {
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
        }
      });
      addTearDown(() async {
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      });

      await _withTempCwd(() async {
        final uri = 'ws://127.0.0.1:${server.port}/zombie/ws';
        final stopwatch = Stopwatch()..start();
        final exitCode = await FlutterScoutCli().run([
          'attach',
          '--debug-url',
          uri,
        ]);
        stopwatch.stop();

        expect(exitCode, 1);
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 30)),
          reason: 'attach should fail fast, not hang, on a dead vm service',
        );
      });
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  group('batch script parsing', () {
    test('splitBatchScript splits on ; and newlines outside quotes', () {
      expect(
        FlutterScoutCli.splitBatchScript(
          "tap btn.save; wait-for --text 'Saved; done'\ninspect --brief",
        ),
        ['tap btn.save', "wait-for --text 'Saved; done'", 'inspect --brief'],
      );
      expect(FlutterScoutCli.splitBatchScript('# comment\ntap a;;\n  \n'), [
        'tap a',
      ]);
    });

    test('splitCommandLine honors quotes and escapes', () {
      expect(
        FlutterScoutCli.splitCommandLine(
          'input --target field.tnc "Terms & Conditions" extra',
        ),
        ['input', '--target', 'field.tnc', 'Terms & Conditions', 'extra'],
      );
      expect(FlutterScoutCli.splitCommandLine("tap-text 'T&C'"), [
        'tap-text',
        'T&C',
      ]);
      expect(
        FlutterScoutCli.splitCommandLine('tap-text --text "-Hair Dye - Plum"'),
        ['tap-text', '--text', '-Hair Dye - Plum'],
      );
      expect(
        FlutterScoutCli.splitCommandLine('crop --text "-Hair Dye - Plum"'),
        ['crop', '--text', '-Hair Dye - Plum'],
      );
      expect(FlutterScoutCli.splitCommandLine('wait-for --text "Saved; ok"'), [
        'wait-for',
        '--text',
        'Saved; ok',
      ]);
      expect(FlutterScoutCli.splitCommandLine('   '), isEmpty);
    });

    test('batch refuses nesting and empty scripts', () async {
      await _withTempCwd(() async {
        final cli = FlutterScoutCli();
        expect(await cli.run(['batch', 'batch inspect']), 1);
        expect(await cli.run(['batch', '   ']), 1);
      });
    });
  });

  group('session registry', () {
    test('named sessions use isolated runtime directories', () {
      final first = FlutterScoutCli.debugNamedSessionDirectory(
        '/workspace',
        'feature A',
      );
      final second = FlutterScoutCli.debugNamedSessionDirectory(
        '/workspace',
        'feature B',
      );

      expect(first, '/workspace/.flutter_scout/sessions/feature-a');
      expect(second, '/workspace/.flutter_scout/sessions/feature-b');
      expect(first, isNot(second));
    });

    test(
      'named sessions bind to the Flutter project instead of command cwd',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'scout_canonical_session_',
        );
        addTearDown(() async {
          if (root.existsSync()) await root.delete(recursive: true);
        });
        File(p.join(root.path, '.git')).writeAsStringSync('gitdir: test');
        final app = Directory(p.join(root.path, 'apps', 'tunaipro'))
          ..createSync(recursive: true);
        final previous = Directory.current;
        addTearDown(() => Directory.current = previous);

        Directory.current = root;
        final fromWorkspace =
            FlutterScoutCli.debugCanonicalNamedSessionDirectory(
              p.join('apps', 'tunaipro'),
              'whatsapp-local-test',
            );
        Directory.current = app;
        final fromApp = FlutterScoutCli.debugCanonicalNamedSessionDirectory(
          '.',
          'whatsapp-local-test',
        );

        expect(fromWorkspace, fromApp);
        expect(
          fromApp,
          p.join(
            app.resolveSymbolicLinksSync(),
            '.flutter_scout',
            'sessions',
            'whatsapp-local-test',
          ),
        );
      },
    );

    test(
      'duplicate same-label roots fail explicitly without replacing registry',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'scout_duplicate_session_',
        );
        addTearDown(() async {
          if (root.existsSync()) await root.delete(recursive: true);
        });
        File(p.join(root.path, '.git')).writeAsStringSync('gitdir: test');
        final app = Directory(p.join(root.path, 'apps', 'tunaipro'))
          ..createSync(recursive: true);
        final workspaceSession = Directory(
          p.join(
            root.path,
            '.flutter_scout',
            'sessions',
            'whatsapp-local-test',
          ),
        )..createSync(recursive: true);
        final appSession = Directory(
          p.join(app.path, '.flutter_scout', 'sessions', 'whatsapp-local-test'),
        )..createSync(recursive: true);
        File(
          p.join(workspaceSession.path, 'session_meta.json'),
        ).writeAsStringSync(
          jsonEncode({
            'name': 'whatsapp-local-test',
            'project': app.path,
            'runId': 'workspace-run',
            'state': 'ready',
          }),
        );
        File(p.join(appSession.path, 'session_meta.json')).writeAsStringSync(
          jsonEncode({
            'name': 'whatsapp-local-test',
            'project': app.path,
            'runId': 'app-run',
            'state': 'ready',
          }),
        );
        FlutterScoutCli.debugRegistryPathOverride = p.join(
          root.path,
          'registry.json',
        );
        addTearDown(() => FlutterScoutCli.debugRegistryPathOverride = null);
        File(FlutterScoutCli.debugRegistryPathOverride!).writeAsStringSync(
          jsonEncode({'whatsapp-local-test': workspaceSession.path}),
        );

        final cli = FlutterScoutCli();
        ScoutCliException? ambiguity;
        try {
          cli.debugResolveRegisteredSessionDirectory(
            'whatsapp-local-test',
            workspaceSession.path,
          );
        } on ScoutCliException catch (error) {
          ambiguity = error;
        }
        expect(ambiguity, isNotNull);
        expect(ambiguity!.code, 'session_selection_required');
        expect(ambiguity.details['reason'], 'duplicate_named_session_roots');
        final candidates = (ambiguity.details['candidates']! as List)
            .cast<Map<String, Object?>>();
        final resolvedWorkspaceSession = workspaceSession
            .resolveSymbolicLinksSync();
        final resolvedAppSession = appSession.resolveSymbolicLinksSync();
        expect(
          candidates.map((candidate) => candidate['sessionDirectory']),
          containsAll([resolvedWorkspaceSession, resolvedAppSession]),
        );
        expect(
          candidates.map((candidate) => candidate['runId']),
          containsAll(['workspace-run', 'app-run']),
        );

        expect(
          () => cli.debugRegisterScoutSession(
            'whatsapp-local-test',
            appSession.path,
            project: app.path,
          ),
          throwsA(
            isA<ScoutCliException>().having(
              (error) => error.code,
              'code',
              'session_selection_required',
            ),
          ),
        );
        final registry =
            jsonDecode(
                  File(
                    FlutterScoutCli.debugRegistryPathOverride!,
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(registry['whatsapp-local-test'], workspaceSession.path);
        expect(await cli.run(['--app', 'whatsapp-local-test', 'status']), 1);
      },
    );

    test(
      'empty legacy directories do not masquerade as active sessions',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'scout_empty_session_root_',
        );
        addTearDown(() async {
          if (root.existsSync()) await root.delete(recursive: true);
        });
        File(p.join(root.path, '.git')).writeAsStringSync('gitdir: test');
        final app = Directory(p.join(root.path, 'apps', 'tunaipro'))
          ..createSync(recursive: true);
        final workspaceSession = Directory(
          p.join(root.path, '.flutter_scout', 'sessions', 'same-label'),
        )..createSync(recursive: true);
        Directory(
          p.join(app.path, '.flutter_scout', 'sessions', 'same-label'),
        ).createSync(recursive: true);
        File(
          p.join(workspaceSession.path, 'session_meta.json'),
        ).writeAsStringSync(
          jsonEncode({
            'name': 'same-label',
            'project': app.path,
            'runId': 'only-real-run',
            'state': 'ready',
          }),
        );

        expect(
          FlutterScoutCli()
              .debugResolveRegisteredSessionDirectory(
                'same-label',
                workspaceSession.path,
              )
              .toString(),
          workspaceSession.resolveSymbolicLinksSync(),
        );
      },
    );

    test('--app resolves a registered session directory', () async {
      final temp = await Directory.systemTemp.createTemp('scout_registry_');
      addTearDown(() => temp.delete(recursive: true));
      FlutterScoutCli.debugRegistryPathOverride = p.join(
        temp.path,
        'registry.json',
      );
      addTearDown(() => FlutterScoutCli.debugRegistryPathOverride = null);

      final sessionDir = Directory(p.join(temp.path, 'proj'))
        ..createSync(recursive: true);
      File(
        FlutterScoutCli.debugRegistryPathOverride!,
      ).writeAsStringSync(jsonEncode({'my-app': sessionDir.path}));

      final previous = Directory.current;
      addTearDown(() => Directory.current = previous);
      // Status targets that session without changing the caller's cwd.
      final cli = FlutterScoutCli();
      expect(await cli.run(['--app', 'my-app', 'status']), 0);
      expect(
        Directory.current.resolveSymbolicLinksSync(),
        previous.resolveSymbolicLinksSync(),
      );

      // Unknown name fails with the registered names listed.
      expect(await cli.run(['--app', 'nope', 'status']), 1);
    });

    test('commands reuse the sole named session from its project', () async {
      await _withTempCwd(() async {
        final named = Directory(
          p.join('.flutter_scout', 'sessions', 'feature-a'),
        )..createSync(recursive: true);
        File(p.join(named.path, 'session_meta.json')).writeAsStringSync(
          jsonEncode({
            'mode': 'attach_only',
            'state': 'ready',
            'name': 'feature-a',
          }),
        );

        expect(await FlutterScoutCli().run(['status']), 0);
        expect(File(p.join(named.path, 'events.jsonl')).existsSync(), isTrue);
        expect(
          File(p.join('.flutter_scout', 'events.jsonl')).existsSync(),
          isFalse,
        );
      });
    });

    test('commands refuse to guess between named sessions', () async {
      await _withTempCwd(() async {
        for (final name in const ['feature-a', 'feature-b']) {
          final named = Directory(p.join('.flutter_scout', 'sessions', name))
            ..createSync(recursive: true);
          File(p.join(named.path, 'session_meta.json')).writeAsStringSync(
            jsonEncode({'mode': 'attach_only', 'state': 'ready', 'name': name}),
          );
        }

        expect(await FlutterScoutCli().run(['status']), 1);
      });
    });

    test('apps hides missing sessions and can prune them', () async {
      final temp = await Directory.systemTemp.createTemp('scout_apps_');
      addTearDown(() => temp.delete(recursive: true));
      FlutterScoutCli.debugRegistryPathOverride = p.join(
        temp.path,
        'registry.json',
      );
      addTearDown(() => FlutterScoutCli.debugRegistryPathOverride = null);
      final live = Directory(p.join(temp.path, 'live'))..createSync();
      File(FlutterScoutCli.debugRegistryPathOverride!).writeAsStringSync(
        jsonEncode({
          'live': live.path,
          'missing': p.join(temp.path, 'missing'),
        }),
      );

      expect(await FlutterScoutCli().run(['apps']), 0);
      expect(await FlutterScoutCli().run(['apps', '--prune']), 0);
      final registry =
          jsonDecode(
                File(
                  FlutterScoutCli.debugRegistryPathOverride!,
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(registry.keys, ['live']);
    });

    test(
      'stop --clear-session prunes registry entries for the session',
      () async {
        final temp = await Directory.systemTemp.createTemp('scout_prune_');
        addTearDown(() => temp.delete(recursive: true));
        FlutterScoutCli.debugRegistryPathOverride = p.join(
          temp.path,
          'registry.json',
        );
        addTearDown(() => FlutterScoutCli.debugRegistryPathOverride = null);
        final sessionDir = Directory(p.join(temp.path, 'proj'))
          ..createSync(recursive: true);
        final otherDir = Directory(p.join(temp.path, 'other'))
          ..createSync(recursive: true);
        File(FlutterScoutCli.debugRegistryPathOverride!).writeAsStringSync(
          jsonEncode({'gone': sessionDir.path, 'kept': otherDir.path}),
        );

        final previous = Directory.current;
        addTearDown(() => Directory.current = previous);
        Directory.current = sessionDir;
        expect(await FlutterScoutCli().run(['stop', '--clear-session']), 0);
        final registry =
            jsonDecode(
                  File(
                    FlutterScoutCli.debugRegistryPathOverride!,
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(registry.containsKey('gone'), isFalse);
        expect(registry['kept'], otherDir.path);
      },
    );
  });

  group('export-batch', () {
    test('reconstructs recorded actions as a runnable script', () async {
      await _withTempCwd(() async {
        final sessionDir = Directory('.flutter_scout')..createSync();
        File(p.join(sessionDir.path, 'session.json')).writeAsStringSync(
          jsonEncode([
            {'cmd': 'tap', 'target': 'btn.save', 'waitMs': '1500'},
            {
              'cmd': 'tap-text',
              'text': 'T&C',
              'waitMs': '800',
              'expectText': 'Saved',
              'expectTimeoutMs': '5000',
            },
            {'cmd': 'tap-text', 'text': '-Hair Dye - Plum', 'waitMs': '1500'},
            {'cmd': 'input', 'target': 'field.name', 'value': 'QA name'},
            {'cmd': 'scroll', 'direction': 'down', 'distance': '300'},
            {'cmd': 'scroll-to', 'target': 'tap.calendar', 'maxScrolls': '6'},
            {
              'cmd': 'scroll-to',
              'target': 'tap.calendar',
              'maxScrolls': '6',
              'direction': 'up',
            },
            {'cmd': 'bogus-thing', 'x': '1'},
          ]),
        );
        final out = 'flow.scout';
        expect(await FlutterScoutCli().run(['export-batch', '-o', out]), 0);
        final script = File(out).readAsStringSync();
        final lines = script.trim().split('\n');
        expect(lines, [
          'tap btn.save',
          "tap-text 'T&C' --wait-ms 800 --expect-text Saved",
          "tap-text --text '-Hair Dye - Plum'",
          "input --target field.name ' VAR:field.name'",
          'scroll down --distance 300',
          'scroll-to tap.calendar --max-scrolls 6',
          'scroll-to tap.calendar --max-scrolls 6 --direction up',
        ]);
        // Round-trips through the batch splitter.
        expect(FlutterScoutCli.splitCommandLine(lines[1]), [
          'tap-text',
          'T&C',
          '--wait-ms',
          '800',
          '--expect-text',
          'Saved',
        ]);
      });
    });
  });

  group('serve', () {
    test('daemon enforces the authenticated bounded typed protocol', () async {
      final publishedCatalog =
          jsonDecode(
                File(
                  '../../protocol/schemas/v1/persistent-methods.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      await _withTempCwd(() async {
        FlutterScoutCli.debugRegistryPathOverride = p.join(
          Directory.current.path,
          'registry.json',
        );
        try {
          final portFile = p.join(Directory.current.path, 'serve.port');
          final credentialFile = '$portFile.credential';
          final cli = FlutterScoutCli();
          final serving = cli.run([
            'serve',
            '--port-file',
            portFile,
            '--max-body-bytes',
            '128',
            '--request-timeout',
            '2',
          ]);
          await _waitForFile(portFile);
          await _waitForFile(credentialFile);
          final port = int.parse(File(portFile).readAsStringSync());
          final authorization = _readTestAuthorization(credentialFile);
          expect(authorization.startsWith('Bearer '), isTrue);
          if (!Platform.isWindows) {
            expect(File(credentialFile).statSync().mode & 0x1ff, 0x180);
          }
          final sessionMeta = File(
            p.join('.flutter_scout', 'session_meta.json'),
          ).readAsStringSync();
          expect(sessionMeta, isNot(contains(authorization)));

          final client = HttpClient();
          try {
            final unauthenticatedHealth = await _serveRequest(
              client,
              port,
              'GET',
              '/health',
            );
            expect(unauthenticatedHealth.statusCode, HttpStatus.unauthorized);
            expect(unauthenticatedHealth.body, isNot(contains('appHealth')));
            expect(unauthenticatedHealth.body, isNot(contains('operability')));

            final health = await _serveRequest(
              client,
              port,
              'GET',
              '/health',
              authorization: authorization,
            );
            expect(health.statusCode, HttpStatus.ok);
            expect(health.body['ok'], isTrue);
            expect(health.body['address'], '127.0.0.1');
            expect(health.body['transportHealthy'], isTrue);
            expect(health.body['appReachable'], isFalse);
            expect(health.body['healthy'], isFalse);
            expect(health.body['transport'], containsPair('status', 'ready'));
            expect(health.body['appHealth'], isA<Map>());
            expect(health.body['operability'], isA<Map>());
            final healthOperability = health.body['operability']! as Map;
            expect(
              healthOperability['prioritizedRecoveryAction'],
              containsPair('action', contains('ensure')),
            );

            final schema = await _serveRequest(
              client,
              port,
              'GET',
              '/v1/schema',
            );
            expect(schema.statusCode, HttpStatus.ok);
            expect(schema.body['protocol'], 'flutter-scout-agent');
            expect(schema.body['version'], 2);
            expect(schema.body['methods'], contains('tap'));
            expect(
              (schema.body['methods'] as List<dynamic>).toSet(),
              (publishedCatalog['methods'] as Map<String, dynamic>).keys
                  .toSet(),
            );
            expect(
              schema.body['parameterAllowlist'],
              publishedCatalog['methods'],
            );
            expect(
              (schema.body['parameterAllowlist'] as Map)['crop'],
              contains('changedSince'),
            );
            expect(schema.body['legacyRun'], containsPair('enabled', false));
            expect(jsonEncode(schema.body), isNot(contains(authorization)));

            final wrongMethod = await _serveRequest(
              client,
              port,
              'GET',
              '/v1/call',
            );
            expect(wrongMethod.statusCode, HttpStatus.methodNotAllowed);
            expect(
              (wrongMethod.body['error'] as Map)['code'],
              'method_not_allowed',
            );

            final unauthenticated = await _serveRequest(
              client,
              port,
              'POST',
              '/v1/call',
              contentType: ContentType.json.mimeType,
              body: jsonEncode({'method': 'apps'}),
            );
            expect(unauthenticated.statusCode, HttpStatus.unauthorized);
            expect(
              (unauthenticated.body['error'] as Map)['code'],
              'invalid_credential',
            );

            final wrongContentType = await _serveRequest(
              client,
              port,
              'POST',
              '/v1/call',
              authorization: authorization,
              contentType: ContentType.text.mimeType,
              body: jsonEncode({'method': 'apps'}),
            );
            expect(
              wrongContentType.statusCode,
              HttpStatus.unsupportedMediaType,
            );

            final crossOrigin = await _serveRequest(
              client,
              port,
              'POST',
              '/v1/call',
              authorization: authorization,
              contentType: ContentType.json.mimeType,
              body: jsonEncode({'method': 'apps'}),
              headers: const {'origin': 'https://attacker.example'},
            );
            expect(crossOrigin.statusCode, HttpStatus.forbidden);
            expect(
              (crossOrigin.body['error'] as Map)['code'],
              'origin_not_allowed',
            );

            final invalidDeadline = await _serveRequest(
              client,
              port,
              'POST',
              '/v1/call',
              authorization: authorization,
              contentType: ContentType.json.mimeType,
              body: jsonEncode({'method': 'apps'}),
              headers: const {'x-flutter-scout-deadline-ms': '0'},
            );
            expect(invalidDeadline.statusCode, HttpStatus.badRequest);
            expect(
              (invalidDeadline.body['error'] as Map)['code'],
              'invalid_deadline',
            );

            final oversized = await _serveRequest(
              client,
              port,
              'POST',
              '/v1/call',
              authorization: authorization,
              contentType: ContentType.json.mimeType,
              body: jsonEncode({'method': 'apps', 'padding': 'x' * 200}),
            );
            expect(oversized.statusCode, HttpStatus.requestEntityTooLarge);
            expect(
              (oversized.body['error'] as Map)['code'],
              'request_body_too_large',
            );

            final unknownParameter = await _serveRequest(
              client,
              port,
              'POST',
              '/v1/call',
              authorization: authorization,
              contentType: ContentType.json.mimeType,
              body: jsonEncode({
                'method': 'apps',
                'params': {'replace': true},
              }),
            );
            expect(unknownParameter.statusCode, HttpStatus.ok);
            expect(
              (unknownParameter.body['error'] as Map)['code'],
              'unknown_parameter',
            );

            final changedRegionParameter = await _serveRequest(
              client,
              port,
              'POST',
              '/v1/call',
              authorization: authorization,
              contentType: ContentType.json.mimeType,
              body: jsonEncode({
                'method': 'crop',
                'params': {'changedSince': 'g0:x'},
              }),
            );
            expect(changedRegionParameter.statusCode, HttpStatus.ok);
            expect(changedRegionParameter.body['exitCode'], 1);
            expect(
              changedRegionParameter.body['structuredError'],
              containsPair('code', 'invalid_snapshot_id'),
            );

            final typed = await _serveRequest(
              client,
              port,
              'POST',
              '/v1/call',
              authorization: authorization,
              contentType: ContentType.json.mimeType,
              body: jsonEncode({'method': 'apps'}),
            );
            expect(typed.statusCode, HttpStatus.ok);
            expect(typed.body['exitCode'], 0);
            expect(typed.body['result'], containsPair('ok', true));

            // Ordinary CLI commands discover the credential file through
            // session metadata and proxy without placing the credential in
            // argv, stdout, or the event log.
            expect(await FlutterScoutCli().run(['health']), 1);
            final events = File(
              p.join('.flutter_scout', 'events.jsonl'),
            ).readAsStringSync();
            expect(events, contains('"transport":"persistent"'));
            expect(events, isNot(contains(authorization)));

            final legacy = await _serveRequest(
              client,
              port,
              'POST',
              '/run',
              authorization: authorization,
              contentType: ContentType.text.mimeType,
              body: 'apps',
            );
            expect(legacy.statusCode, HttpStatus.notFound);
            expect(
              (legacy.body['error'] as Map)['code'],
              'legacy_run_disabled',
            );

            final stopByGet = await _serveRequest(
              client,
              port,
              'GET',
              '/stop',
              authorization: authorization,
            );
            expect(stopByGet.statusCode, HttpStatus.methodNotAllowed);

            final stop = await _serveRequest(
              client,
              port,
              'POST',
              '/stop',
              authorization: authorization,
            );
            expect(stop.statusCode, HttpStatus.ok);
            expect(stop.body['stopping'], isTrue);
            expect(await serving, 0);
            expect(File(credentialFile).existsSync(), isFalse);
          } finally {
            client.close(force: true);
          }
        } finally {
          FlutterScoutCli.debugRegistryPathOverride = null;
        }
      });
    });

    test(
      'legacy free-form endpoint requires explicit authenticated opt-in',
      () async {
        await _withTempCwd(() async {
          FlutterScoutCli.debugRegistryPathOverride = p.join(
            Directory.current.path,
            'registry.json',
          );
          try {
            final portFile = p.join(Directory.current.path, 'legacy.port');
            final credentialFile = '$portFile.credential';
            final serving = FlutterScoutCli().run([
              'serve',
              '--port-file',
              portFile,
              '--allow-legacy-run',
            ]);
            await _waitForFile(portFile);
            await _waitForFile(credentialFile);
            final port = int.parse(File(portFile).readAsStringSync());
            final authorization = _readTestAuthorization(credentialFile);
            final client = HttpClient();
            try {
              final queryForm = await _serveRequest(
                client,
                port,
                'GET',
                '/run?cmd=apps',
                authorization: authorization,
              );
              expect(queryForm.statusCode, HttpStatus.methodNotAllowed);

              final run = await _serveRequest(
                client,
                port,
                'POST',
                '/run',
                authorization: authorization,
                contentType: ContentType.text.mimeType,
                body: 'apps',
              );
              expect(run.statusCode, HttpStatus.ok);
              expect(run.body['exitCode'], 0);
              final result = run.body['result'] as Map<String, dynamic>;
              expect(result['ok'], isTrue);
              expect(result.containsKey('sessions'), isTrue);
              expect(run.body.containsKey('output'), isFalse);

              final nested = await _serveRequest(
                client,
                port,
                'POST',
                '/run',
                authorization: authorization,
                contentType: ContentType.text.mimeType,
                body: '--app any serve',
              );
              expect(nested.body['exitCode'], 1);
              expect(
                nested.body['error'],
                allOf(
                  containsPair('code', 'command_failed'),
                  containsPair(
                    'message',
                    'nested persistent mode is not supported',
                  ),
                ),
              );

              final stop = await _serveRequest(
                client,
                port,
                'POST',
                '/stop',
                authorization: authorization,
              );
              expect(stop.body['stopping'], isTrue);
              expect(await serving, 0);
              expect(File(credentialFile).existsSync(), isFalse);

              final rotatedPortFile = p.join(
                Directory.current.path,
                'rotated.port',
              );
              final rotatedCredentialFile = '$rotatedPortFile.credential';
              final rotatedServing = FlutterScoutCli().run([
                'serve',
                '--port-file',
                rotatedPortFile,
              ]);
              await _waitForFile(rotatedPortFile);
              await _waitForFile(rotatedCredentialFile);
              final rotatedPort = int.parse(
                File(rotatedPortFile).readAsStringSync(),
              );
              final rotatedAuthorization = _readTestAuthorization(
                rotatedCredentialFile,
              );
              expect(rotatedAuthorization == authorization, isFalse);
              final rotatedStop = await _serveRequest(
                client,
                rotatedPort,
                'POST',
                '/stop',
                authorization: rotatedAuthorization,
              );
              expect(rotatedStop.body['stopping'], isTrue);
              expect(await rotatedServing, 0);
            } finally {
              client.close(force: true);
            }
          } finally {
            FlutterScoutCli.debugRegistryPathOverride = null;
          }
        });
      },
    );
  });

  group('helper protocol diagnostics', () {
    test(
      'compact action output announces automatic persistent transport',
      () async {
        await _withTempCwd(() async {
          final sessionDir = Directory('.flutter_scout')..createSync();
          File(p.join(sessionDir.path, 'session.json')).writeAsStringSync(
            jsonEncode([
              {'cmd': 'tap', 'target': 'btn.one'},
              {'cmd': 'tap', 'target': 'btn.two'},
              {'cmd': 'tap', 'target': 'btn.three'},
            ]),
          );

          final cli = FlutterScoutCli();
          final result = cli.debugCompactActionResult({
            'ok': true,
            'action': 'tap btn.four',
            'result': 'changed',
          });

          final hints = result['workflowHints'] as List<Object?>;
          expect(
            hints.single,
            containsPair('code', 'automatic_persistent_transport'),
          );
          final repeated = cli.debugCompactActionResult({
            'ok': true,
            'action': 'tap btn.five',
            'result': 'changed',
          });
          expect(repeated.containsKey('workflowHints'), isFalse);
        });
      },
    );

    test('modern helper version passes clean, even for brief payloads', () {
      final cli = FlutterScoutCli();
      final result = cli.debugProtocolDiagnostics('ext.flutter_scout.inspect', {
        'ok': true,
        'helperProtocolVersion': FlutterScoutCli.expectedHelperProtocolVersion,
        'screen': 'HomeScreen',
        // Brief payload intentionally has no textTargets: must NOT be treated
        // as an old helper.
      });
      expect(result.containsKey('helperProtocol'), isFalse);
      expect(result.containsKey('warnings'), isFalse);
    });

    test('older helper version warns once per session', () async {
      await _withTempCwd(() async {
        final cli = FlutterScoutCli();
        final result = cli.debugProtocolDiagnostics(
          'ext.flutter_scout.inspect',
          {'ok': true, 'helperProtocolVersion': 1, 'screen': 'HomeScreen'},
        );
        final protocol = result['helperProtocol'] as Map<String, dynamic>;
        expect(protocol['status'], 'older_than_cli');
        expect(protocol['helperProtocolVersion'], 1);
        expect(result['warnings'], isNotEmpty);
        expect(
          result['protocolMismatch'],
          '1<${FlutterScoutCli.expectedHelperProtocolVersion}',
        );

        final repeated = cli.debugProtocolDiagnostics(
          'ext.flutter_scout.inspect',
          {'ok': true, 'helperProtocolVersion': 1, 'screen': 'HomeScreen'},
        );
        expect(
          repeated['protocolMismatch'],
          '1<${FlutterScoutCli.expectedHelperProtocolVersion}',
        );
        expect(repeated.containsKey('helperProtocol'), isFalse);
        expect(repeated.containsKey('warnings'), isFalse);
      });
    });

    test('version-less helper falls back to field heuristics', () async {
      await _withTempCwd(() async {
        final cli = FlutterScoutCli();
        final result = cli.debugProtocolDiagnostics(
          'ext.flutter_scout.inspect',
          {'ok': true, 'screen': 'HomeScreen'},
        );
        final protocol = result['helperProtocol'] as Map<String, dynamic>;
        expect(protocol['status'], 'stale_or_old_helper');
      });
    });
  });

  test('compact action output omits heavy inspect sections', () {
    final cli = FlutterScoutCli();
    final result = cli.debugCompactActionResult({
      'ok': true,
      'action': 'tap btn.payment',
      'result': 'activated',
      'after': {
        'screen': 'Payment',
        'routeGuess': 'HomeScreen',
        'viewSignature': 'Payment | Cash | Confirm',
        'visibleTextHash': '12345678',
        'idle': true,
        'visibleText': List<String>.generate(20, (index) => 'text $index'),
        'hitTestableText': ['Payment', 'Confirm Payment'],
        'offscreenText': ['hidden'],
        'fieldValues': {'field.note': ''},
        'fieldsById': {
          'field.note': {'label': 'Note'},
        },
        'visualTree': {'children': List<int>.generate(100, (index) => index)},
        'controlGroups': [
          {'kind': 'keypad'},
        ],
        'suggestedActions': [
          {'intent': 'enterValue'},
        ],
        'structuredRows': [
          {
            'id': 'row.payment',
            'label': 'Payment',
            'text': List<String>.generate(20, (index) => 'row $index'),
            'actions': List<int>.generate(20, (index) => index),
          },
        ],
      },
    });

    expect(result['screen'], 'Payment');
    expect(result['sameSnapshot'], isTrue);
    expect(result.containsKey('afterSummary'), isFalse);
    expect(result.containsKey('visualTree'), isFalse);
    expect(result.containsKey('controlGroups'), isFalse);
    expect(result.containsKey('fieldsById'), isFalse);
    expect(result.containsKey('structuredRows'), isFalse);
    expect(result.containsKey('visibleText'), isFalse);
  });

  test(
    'brief inspect preserves state identity and compresses text overlap',
    () {
      final result = FlutterScoutCli().debugCompactBriefInspect({
        'ok': true,
        'helperProtocolVersion': FlutterScoutCli.expectedHelperProtocolVersion,
        'runtimeInstanceId': 'runtime-a',
        'stateGeneration': 12,
        'stateDigest': List<String>.filled(64, 'a').join(),
        'snapshotId': 'g12:${List<String>.filled(64, 'a').join()}',
        'errorCursor': 4,
        'errorsSinceCursor': <Object?>[],
        'routeGuess': null,
        'visibleText': ['Search', 'Save', 'Cancel'],
        'hitTestableText': ['Save', 'Cancel'],
        'offscreenText': <String>[],
        'fieldValues': <String, Object?>{},
      });

      expect(result.containsKey('helperProtocolVersion'), isFalse);
      expect(result['runtimeInstanceId'], 'runtime-a');
      expect(result['stateGeneration'], 12);
      expect(result, contains('stateDigest'));
      expect(result, contains('snapshotId'));
      expect(result['errorCursor'], 4);
      expect(result['errorsSinceCursor'], isEmpty);
      expect(result.containsKey('routeGuess'), isFalse);
      expect(result.containsKey('hitTestableText'), isFalse);
      expect(result['nonHitTestableText'], ['Search']);
      expect(result.containsKey('offscreenText'), isFalse);
      expect(result.containsKey('fieldValues'), isFalse);
    },
  );

  test(
    'post-action capture is materialized without duplicated base64 output',
    () async {
      final temp = await Directory.systemTemp.createTemp('scout_capture_');
      addTearDown(() => temp.delete(recursive: true));
      final output = p.join(temp.path, 'capture.png');
      final bytes = List<int>.generate(96 * 1024, (index) => index % 251);
      final encoded = base64Encode(bytes);
      final result = FlutterScoutCli().debugMaterializeActionCapture({
        'ok': true,
        'capture': {'ok': true, 'bytes': encoded, 'backend': 'in_app_capture'},
        'result': {
          'action': 'tap',
          'capture': {
            'ok': true,
            'bytes': encoded,
            'backend': 'in_app_capture',
          },
        },
      }, output);

      expect(File(output).readAsBytesSync(), bytes);
      expect(
        result['capture'],
        allOf(
          isNot(contains('bytes')),
          containsPair('path', File(output).absolute.path),
        ),
      );
      final nestedResult = result['result']! as Map;
      expect(
        nestedResult['capture'],
        allOf(
          isNot(contains('bytes')),
          containsPair('path', File(output).absolute.path),
        ),
      );
      expect(jsonEncode(result), isNot(contains(encoded)));
    },
  );

  test('assert-no-errors converts fresh blocking signals into failure', () {
    final result = FlutterScoutCli().debugAssertActionHasNoErrors({
      'ok': true,
      'errorsSinceCursor': [
        {
          'cursor': 8,
          'blocking': true,
          'stale': false,
          'message': 'fresh framework error',
        },
      ],
      'recentLogSignals': [
        {'blocking': true, 'stale': false, 'message': 'build failed'},
      ],
    });

    expect(result['ok'], isFalse);
    expect(result['error'], containsPair('code', 'blocking_errors_observed'));
    expect(result['blockingErrors'], hasLength(1));
  });

  test(
    'temporary helper setup leaves tracked inputs unchanged',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'scout_temporary_helper_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final pubspec = File(p.join(temp.path, 'pubspec.yaml'))
        ..writeAsStringSync('''
name: temporary_scout_app
environment:
  sdk: ^3.12.0
dependencies:
  flutter:
    sdk: flutter
''');
      final mainFile = File(p.join(temp.path, 'lib', 'main.dart'));
      mainFile.parent.createSync(recursive: true);
      mainFile.writeAsStringSync('''
import 'package:flutter/widgets.dart';
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox());
}
''');
      final originalPubspec = pubspec.readAsBytesSync();
      final helperPath = p.normalize(
        p.join(Directory.current.path, '..', 'flutter_scout_helper'),
      );
      FlutterScoutCli.debugTemporaryHelperPubGetOverride = (project) async {
        final hasHelper = File(
          p.join(project, 'pubspec.yaml'),
        ).readAsStringSync().contains('flutter_scout_helper:');
        final packageConfig = File(
          p.join(project, '.dart_tool', 'package_config.json'),
        );
        packageConfig.parent.createSync(recursive: true);
        packageConfig.writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': hasHelper
                ? [
                    {'name': 'flutter_scout_helper'},
                  ]
                : const <Object?>[],
          }),
          flush: true,
        );
        File(p.join(project, 'pubspec.lock')).writeAsStringSync(
          hasHelper ? 'helper transaction lock\n' : 'cleanup lock\n',
          flush: true,
        );
        return ProcessResult(1, 0, '', '');
      };
      addTearDown(() {
        FlutterScoutCli.debugTemporaryHelperPubGetOverride = null;
      });

      final cli = FlutterScoutCli();
      final setup = await cli.debugPrepareTemporaryHelper(
        project: temp.path,
        helperPath: helperPath,
      );

      expect(pubspec.readAsBytesSync(), originalPubspec);
      expect(File(p.join(temp.path, 'pubspec.lock')).existsSync(), isFalse);
      expect(File(setup['targetPath']!.toString()).existsSync(), isTrue);
      expect(
        File(
          p.join(temp.path, '.dart_tool', 'package_config.json'),
        ).readAsStringSync(),
        contains('flutter_scout_helper'),
      );

      final cleanup = await cli.debugCleanupTemporaryHelper(setup);
      expect(cleanup['targetRemoved'], isTrue);
      expect(cleanup['packageConfigRestored'], isTrue);
      expect(File(p.join(temp.path, 'pubspec.lock')).existsSync(), isFalse);
      expect(
        File(
          p.join(temp.path, '.dart_tool', 'package_config.json'),
        ).readAsStringSync(),
        isNot(contains('flutter_scout_helper')),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('compact held-drag output keeps position and path progress', () {
    final cli = FlutterScoutCli();
    final result = cli.debugCompactActionResult({
      'ok': true,
      'action': 'drag-move',
      'active': true,
      'position': [120, 420],
      'pathLength': 3,
      'snapshot': {
        'screen': 'GestureLabScreen',
        'visibleText': ['Drag lab'],
      },
    });

    expect(result['active'], isTrue);
    expect(result['position'], [120, 420]);
    expect(result['pathLength'], 3);
  });

  test('compact wait output reports actual wait without full snapshot', () {
    final cli = FlutterScoutCli();
    final result = cli.debugCompactActionResult({
      'ok': true,
      'stable': true,
      'waitedMs': 96,
      'snapshot': {
        'screen': 'HomeScreen',
        'visualTree': List<int>.generate(100, (index) => index),
      },
    });

    expect(result['stable'], isTrue);
    expect(result['waitedMs'], 96);
    expect(result.containsKey('snapshot'), isFalse);
  });

  test('Scout-owned tool URI wins over another app marker in mixed logs', () {
    final cli = FlutterScoutCli();
    final uri = cli.debugPreferredVmUriFromLogText('''
A Dart VM Service is available at: http://127.0.0.1:51000/owned=/
[2026-07-21T14:00:00] [VM_LOG] [FLUTTER_SCOUT_VM_URI] http://127.0.0.1:52000/other=/
''');

    expect(uri, 'http://127.0.0.1:51000/owned=/');
  });

  test('compact action output compacts failed expectation payloads', () {
    final cli = FlutterScoutCli();
    final result = cli.debugCompactActionResult({
      'ok': false,
      'error': {'code': 'expectation_not_met', 'message': 'Timed out'},
      'action': 'tap btn.save',
      'result': 'activated_no_observed_change',
      'target': {
        'id': 'btn.save',
        'label': 'Save',
        'kind': 'btn',
        'rect': [1, 2, 300, 80],
        'heuristicScore': 0.95,
        'scoreKind': 'uncalibrated_heuristic',
      },
      'expectation': {
        'met': false,
        'conditions': {'text': 'Saved'},
      },
      'before': {
        'screen': 'EditScreen',
        'viewSignature': 'Edit | Save',
        'visibleTextHash': 'before-hash',
        'visibleText': List<String>.generate(25, (index) => 'before $index'),
        'textTargets': List<int>.generate(100, (index) => index),
      },
      'after': {
        'screen': 'EditScreen',
        'viewSignature': 'Edit | Save',
        'visibleTextHash': 'after-hash',
        'visibleText': List<String>.generate(25, (index) => 'after $index'),
        'visualTree': {'children': List<int>.generate(100, (index) => index)},
      },
      'recentErrors': [
        {'message': 'old'},
        {'message': 'middle'},
        {'message': 'newer'},
        {'message': 'newest'},
      ],
    });

    expect(result['ok'], isFalse);
    expect(result.containsKey('before'), isFalse);
    expect(result.containsKey('after'), isFalse);
    final target = result['target'] as Map<String, Object?>;
    expect(target, {'id': 'btn.save', 'label': 'Save', 'kind': 'btn'});
    final before = result['beforeSummary'] as Map<String, Object?>;
    final after = result['afterSummary'] as Map<String, Object?>;
    expect(before.containsKey('textTargets'), isFalse);
    expect(after.containsKey('visualTree'), isFalse);
    expect(before.containsKey('visibleText'), isFalse);
    expect((result['recentErrors'] as List).length, 3);
  });

  test('compact same-state async action preserves activity facts', () {
    final result = FlutterScoutCli().debugCompactActionResult({
      'ok': true,
      'action': 'tap btn.retry',
      'result': 'completed_same_state',
      'activityObserved': true,
      'transientViewSignatures': ['Error | Loading'],
      'after': {'screen': 'ErrorScreen', 'snapshotId': 'same'},
      'delta': <String, Object?>{},
      'recentLogErrors': ['legacy duplicate'],
    });

    expect(result['activityObserved'], isTrue);
    expect(result['result'], 'completed_same_state');
    expect(result['sameSnapshot'], isTrue);
    expect(result['transientViewSignatures'], ['Error | Loading']);
    expect(result.containsKey('recentLogErrors'), isFalse);
  });

  test('log redaction covers headers, JSON, and bearer credentials', () {
    final cli = FlutterScoutCli();
    final redacted = cli.debugRedactLogText(
      '{"token":"secret","mobileID":"abc"} '
      'Authorization: Bearer xyz.123 session=raw\n\u0085',
    );

    expect(redacted, isNot(contains('secret')));
    expect(redacted, isNot(contains('abc')));
    expect(redacted, isNot(contains('xyz.123')));
    expect(redacted, isNot(contains('session=raw')));
    expect(redacted, contains('<redacted>'));
    expect(redacted, isNot(contains('\n')));
    expect(redacted, isNot(contains('\u0085')));
    expect(redacted, contains(r'\n'));
    expect(redacted, contains(r'\u0085'));
  });

  test('untimestamped historical log signals are stale by default', () {
    final signals = FlutterScoutCli().debugRecentLogSignalsFromLines([
      'Build Error: old failure without a timestamp',
    ]);

    expect(signals, hasLength(1));
    expect(signals.single['cursor'], greaterThan(0));
    expect(signals.single['freshness'], 'unknown');
    expect(signals.single['stale'], isTrue);
  });

  test('log signals classify Flutter build errors without failed-text noise', () {
    final cli = FlutterScoutCli();
    final timestamp = DateTime.now().toIso8601String();
    final signals = cli.debugRecentLogSignalsFromLines([
      '[2026-07-08T12:38:59.000] [VM_LOG] [CloudDebug] level=0 seq=536 status=failed but handled by app state',
      '[$timestamp] [VM_STDERR] #0      _CollapsedToolbarTitle._collapsedOpacity (package:tunaipro/general_module/tunai_whatsapp_module/ui/widget/collapsing_avatar_header_scaffold.dart:495:38)',
      '[$timestamp] [VM_LOG] [TunaiLogger] level=0 seq=537 Build Error: Null check operator used on a null value',
      '��═══════════════════════════',
      '[$timestamp] [VM_STDERR] #1      _CollapsedToolbarTitle.build (package:tunaipro/general_module/tunai_whatsapp_module/ui/widget/collapsing_avatar_header_scaffold.dart:512:17)',
    ]);

    expect(signals, hasLength(1));
    expect(signals.single['kind'], 'flutter_build_error');
    expect(signals.single['severity'], 'blocking');
    expect(signals.single['blocking'], isTrue);
    expect(
      signals.single['message'],
      'Null check operator used on a null value',
    );
    expect(
      signals.single['line'],
      contains('Build Error: Null check operator used on a null value'),
    );
    expect(signals.single['context'], isA<List>());
    expect(
      signals.single['context'].toString(),
      contains('collapsing_avatar_header_scaffold.dart:495:38'),
    );
    expect(signals.single['context'].toString(), isNot(contains('═══')));
  });

  test('log summary reports structured blocking log signals', () {
    final cli = FlutterScoutCli();
    final timestamp = DateTime.now().toIso8601String();
    final summary = cli.debugLogSummary([
      'Flutter run key commands.',
      '[$timestamp] [VM_LOG] [TunaiLogger] level=0 seq=537 Build Error: Null check operator used on a null value',
      '[$timestamp] [VM_STDERR] #0      _CollapsedToolbarTitle._collapsedOpacity (package:tunaipro/widget.dart:495:38)',
      '[2026-07-08T12:39:01.000] [VM_LOG] [CloudDebug] level=0 seq=538 status=failed but not a runtime failure',
    ]);

    expect(summary['errors'], 1);
    expect(summary['warnings'], 0);
    final recentSignals = summary['recentLogSignals'] as List;
    final blockingSignals = summary['blockingLogSignals'] as List;
    expect(recentSignals, hasLength(1));
    expect(blockingSignals, hasLength(1));
    expect((blockingSignals.single as Map)['kind'], 'flutter_build_error');
    expect(
      summary['lastImportantLines'].toString(),
      contains('Build Error: Null check operator used on a null value'),
    );
    expect(
      summary['lastImportantLines'].toString(),
      isNot(contains('seq=538')),
    );
  });

  test('launchd runner plist restarts only an abnormally lost worker', () {
    final plist = FlutterScoutCli().debugLaunchdRunnerPlist(
      label: 'dev.flutter-scout.runner.test',
      configFile: '/tmp/scout & runner/config.json',
      outputFile: '/tmp/scout <runner>/output.txt',
    );

    expect(plist, contains('<string>dev.flutter-scout.runner.test</string>'));
    expect(plist, contains('<key>RunAtLoad</key>\n  <true/>'));
    expect(
      plist,
      contains(
        '<key>KeepAlive</key>\n  <dict>\n'
        '    <key>SuccessfulExit</key>\n    <false/>',
      ),
    );
    expect(plist, contains('/tmp/scout &amp; runner/config.json'));
    expect(plist, contains('/tmp/scout &lt;runner&gt;/output.txt'));
    expect(plist, contains('<key>PATH</key>'));
    expect(
      plist,
      contains('<key>ProcessType</key>\n  <string>Interactive</string>'),
    );
    expect(plist, isNot(contains('<string>Background</string>')));
    expect(plist, isNot(contains('<key>KeepAlive</key>\n  <true/>')));
  });

  test('launch poll accepts the worker identity recorded after Dart exec', () {
    final cli = FlutterScoutCli();
    final initialIdentity = <String, Object?>{
      'pid': 42,
      'parentPid': 1,
      'startedAt': 'Thu Aug 20 17:09:04 2026',
      'executable': '/flutter/bin/cache/dart-sdk/bin/dart',
      'commandIdentity': 'flutter_run_worker',
    };
    final postExecIdentity = <String, Object?>{
      ...initialIdentity,
      'executable': '/flutter/bin/cache/dart-sdk/bin/dartvm',
    };
    final state = <String, dynamic>{
      'runId': 'launch-run',
      'workerPid': 42,
      'workerProcessIdentity': postExecIdentity,
    };

    expect(
      cli.debugSelectRunnerWorkerIdentity(
        initialIdentity: initialIdentity,
        expectedRunId: 'launch-run',
        liveWorkerPid: 42,
        supervisorState: state,
      ),
      same(postExecIdentity),
    );
    expect(
      cli.debugSelectRunnerWorkerIdentity(
        initialIdentity: initialIdentity,
        expectedRunId: 'different-run',
        liveWorkerPid: 42,
        supervisorState: state,
      ),
      same(initialIdentity),
    );
    expect(
      cli.debugSelectRunnerWorkerIdentity(
        initialIdentity: initialIdentity,
        expectedRunId: 'launch-run',
        liveWorkerPid: 99,
        supervisorState: state,
      ),
      same(initialIdentity),
    );
  });

  test('launch poll accepts only the exact Dart VM exec transition', () {
    final cli = FlutterScoutCli();
    final initialIdentity = <String, Object?>{
      'pid': 42,
      'parentPid': 1,
      'startedAt': 'Thu Aug 20 17:09:04 2026',
      'executable': '/flutter/bin/cache/dart-sdk/bin/dart',
      'commandIdentity': 'flutter_run_worker',
    };
    final postExecIdentity = <String, Object?>{
      ...initialIdentity,
      'executable': '/flutter/bin/cache/dart-sdk/bin/dartvm',
    };

    expect(
      cli.debugMatchesRunnerWorkerIdentity(initialIdentity, postExecIdentity),
      isTrue,
    );
    for (final mismatch in <Map<String, Object?>>[
      {...postExecIdentity, 'pid': 43},
      {...postExecIdentity, 'parentPid': 2},
      {...postExecIdentity, 'startedAt': 'Thu Aug 20 17:09:05 2026'},
      {...postExecIdentity, 'commandIdentity': 'foreign_worker'},
      {...postExecIdentity, 'executable': '/tmp/dartvm'},
      {
        ...postExecIdentity,
        'executable': '/flutter/bin/cache/dart-sdk/bin/dartaotruntime',
      },
    ]) {
      expect(
        cli.debugMatchesRunnerWorkerIdentity(initialIdentity, mismatch),
        isFalse,
      );
    }
  });

  test(
    'supervised worker records Flutter exit without requesting relaunch',
    () async {
      await _withTempCwd(() async {
        final runDirectory = Directory('run')..createSync();
        final config = File(p.join(runDirectory.path, 'worker.json'));
        final exitFile = File(p.join(runDirectory.path, 'exit.json'));
        final stateFile = File(p.join(runDirectory.path, 'state.json'));
        config.writeAsStringSync(
          jsonEncode({
            'project': Directory.current.path,
            'flutterExecutable': '/bin/sh',
            'flutterArgs': ['-c', 'exit 7'],
            'logFile': p.join(runDirectory.path, 'flutter.log'),
            'runId': 'test-run',
            'exitFile': exitFile.path,
            'stateFile': stateFile.path,
            'persistentConfig': true,
            'supervised': true,
          }),
        );

        final result = await FlutterScoutCli().run([
          'flutter-run-worker',
          '--config',
          config.path,
        ]);

        expect(result, 0);
        expect(config.existsSync(), isTrue);
        final exit = jsonDecode(exitFile.readAsStringSync()) as Map;
        final state = jsonDecode(stateFile.readAsStringSync()) as Map;
        expect(exit['exitCode'], 7);
        expect(exit['flutterPid'], isA<int>());
        expect(state['launchCount'], 1);
        expect(state['workerExitingNormally'], isTrue);
        expect(state['exitCode'], 7);
        expect(
          Directory('.flutter_scout').existsSync(),
          isFalse,
          reason:
              'Internal workers use their absolute config paths and must not bootstrap session storage from the launchd working directory.',
        );
      });
    },
  );
}

Future<void> _withTempCwd(Future<void> Function() body) async {
  final previous = Directory.current;
  final temp = await Directory.systemTemp.createTemp('flutter_scout_test_');
  try {
    Directory.current = temp;
    await body();
  } finally {
    Directory.current = previous;
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  }
}

Future<void> _waitForFile(String path) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (File(path).existsSync()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('Timed out waiting for test file.');
}

String _readTestAuthorization(String credentialFile) {
  final line = File(credentialFile).readAsStringSync().trim();
  const prefix = 'Authorization: ';
  if (!line.startsWith(prefix)) {
    throw StateError('Serve credential file did not contain an HTTP header.');
  }
  return line.substring(prefix.length);
}

Future<({int statusCode, Map<String, dynamic> body})> _serveRequest(
  HttpClient client,
  int port,
  String method,
  String path, {
  String? authorization,
  String? contentType,
  String? body,
  Map<String, String> headers = const {},
}) async {
  final request = await client.openUrl(
    method,
    Uri.parse('http://127.0.0.1:$port$path'),
  );
  if (authorization != null) {
    request.headers.set(HttpHeaders.authorizationHeader, authorization);
  }
  if (contentType != null) {
    request.headers.contentType = ContentType.parse(contentType);
  }
  for (final entry in headers.entries) {
    request.headers.set(entry.key, entry.value);
  }
  if (body != null) request.write(body);
  final response = await request.close();
  final responseBody = await utf8.decoder.bind(response).join();
  return (
    statusCode: response.statusCode,
    body: jsonDecode(responseBody) as Map<String, dynamic>,
  );
}
