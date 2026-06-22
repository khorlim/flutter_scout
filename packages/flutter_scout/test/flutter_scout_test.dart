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
