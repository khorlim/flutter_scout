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

  test('launch requires a device id', () async {
    await _withTempCwd(() async {
      final exitCode = await FlutterScoutCli().run(['launch']);

      expect(exitCode, 1);
    });
  });

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
      // status against the registered (empty) session: runs from that dir
      // and reports not-running rather than session_not_registered.
      final cli = FlutterScoutCli();
      expect(await cli.run(['--app', 'my-app', 'status']), 0);
      expect(
        Directory.current.resolveSymbolicLinksSync(),
        sessionDir.resolveSymbolicLinksSync(),
      );

      // Unknown name fails with the registered names listed.
      expect(await cli.run(['--app', 'nope', 'status']), 1);
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
          "input --target field.name 'QA name'",
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
    test('daemon runs commands over HTTP and stops on /stop', () async {
      final temp = await Directory.systemTemp.createTemp('scout_serve_');
      addTearDown(() => temp.delete(recursive: true));
      FlutterScoutCli.debugRegistryPathOverride = p.join(
        temp.path,
        'registry.json',
      );
      addTearDown(() => FlutterScoutCli.debugRegistryPathOverride = null);
      final portFile = p.join(temp.path, 'port');

      final cli = FlutterScoutCli();
      final serving = cli.run(['serve', '--port-file', portFile]);
      // Wait for the daemon to write its bound port.
      var waited = 0;
      while (!File(portFile).existsSync() && waited < 100) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        waited++;
      }
      final port = int.parse(File(portFile).readAsStringSync());
      final client = HttpClient();
      addTearDown(client.close);

      Future<Map<String, dynamic>> get(String pathAndQuery) async {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port$pathAndQuery'),
        );
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();
        return jsonDecode(body) as Map<String, dynamic>;
      }

      final health = await get('/health');
      expect(health['ok'], isTrue);

      final apps = await get('/run?cmd=apps');
      expect(apps['exitCode'], 0);
      // Command JSON is nested as an object, not a re-encoded string.
      final appsResult = apps['result'] as Map<String, dynamic>;
      expect(appsResult['ok'], isTrue);
      expect(appsResult.containsKey('sessions'), isTrue);
      expect(apps.containsKey('output'), isFalse);

      final bogus = await get('/run?cmd=serve');
      expect(bogus['exitCode'], 1);

      final stop = await get('/stop');
      expect(stop['stopping'], isTrue);
      expect(await serving, 0);
    });
  });

  group('helper protocol diagnostics', () {
    test(
      'compact action output suggests serve after several plain actions',
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

          final result = FlutterScoutCli().debugCompactActionResult({
            'ok': true,
            'action': 'tap btn.four',
            'result': 'changed',
          });

          final hints = result['workflowHints'] as List<Object?>;
          expect(hints.single, containsPair('code', 'consider_serve'));
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

    test('older helper version is flagged with relaunch guidance', () {
      final cli = FlutterScoutCli();
      final result = cli.debugProtocolDiagnostics('ext.flutter_scout.inspect', {
        'ok': true,
        'helperProtocolVersion': 1,
        'screen': 'HomeScreen',
      });
      final protocol = result['helperProtocol'] as Map<String, dynamic>;
      expect(protocol['status'], 'older_than_cli');
      expect(protocol['helperProtocolVersion'], 1);
      expect(result['warnings'], isNotEmpty);
    });

    test('version-less helper falls back to field heuristics', () {
      final cli = FlutterScoutCli();
      final result = cli.debugProtocolDiagnostics('ext.flutter_scout.inspect', {
        'ok': true,
        'screen': 'HomeScreen',
      });
      final protocol = result['helperProtocol'] as Map<String, dynamic>;
      expect(protocol['status'], 'stale_or_old_helper');
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
      },
    });

    final summary = result['afterSummary'] as Map<String, Object?>;
    expect(summary['screen'], 'Payment');
    expect(summary['viewSignature'], 'Payment | Cash | Confirm');
    expect(summary.containsKey('visualTree'), isFalse);
    expect(summary.containsKey('controlGroups'), isFalse);
    expect(summary.containsKey('fieldsById'), isFalse);
    expect((summary['visibleText'] as List).length, 12);
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
        'confidence': 0.95,
      },
      'expectation': {
        'met': false,
        'conditions': {'text': 'Saved'},
      },
      'before': {
        'screen': 'EditScreen',
        'viewSignature': 'Edit | Save',
        'visibleText': List<String>.generate(25, (index) => 'before $index'),
        'textTargets': List<int>.generate(100, (index) => index),
      },
      'after': {
        'screen': 'EditScreen',
        'viewSignature': 'Edit | Save',
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
    expect((before['visibleText'] as List).length, 12);
    expect((result['recentErrors'] as List).length, 3);
  });
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
