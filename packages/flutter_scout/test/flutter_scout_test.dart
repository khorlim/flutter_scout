import 'dart:io';

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
      expect(FlutterScoutCli.parseSimctlDevices(payload, 'CCCC-UNAVAIL'), isNull);
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

  test('help exits successfully', () async {
    final exitCode = await FlutterScoutCli().run(['--help']);

    expect(exitCode, 0);
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
