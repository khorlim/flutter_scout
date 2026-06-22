import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:test/test.dart';

void main() {
  test('CLI can be constructed', () {
    expect(FlutterScoutCli(), isA<FlutterScoutCli>());
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
