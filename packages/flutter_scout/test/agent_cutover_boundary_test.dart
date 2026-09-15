import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  tearDown(() {
    FlutterScoutCli.debugVmServiceConnectObserver = null;
  });

  test(
    'legacy direct interaction and transport forms cannot reach dispatch',
    () async {
      await _withTemporaryWorkspace(() async {
        var connectionAttempts = 0;
        FlutterScoutCli.debugVmServiceConnectObserver = (_) {
          connectionAttempts++;
        };
        Directory('.flutter_scout').createSync();
        File(FlutterScoutCli.debugRegistryPathOverride!).writeAsStringSync(
          jsonEncode(<String, String>{
            'registered-cutover': Directory.current.path,
          }),
        );

        for (final arguments in const <List<String>>[
          <String>['tap', 'btn.save'],
          <String>[
            '--idempotency-key',
            'legacy-direct-override',
            'tap',
            'btn.save',
          ],
          <String>['tap', 'btn.save', '--agent-lane'],
          <String>['--app', 'registered-cutover', 'tap', 'btn.save'],
          <String>['tap', 'btn.save', '--help'],
          <String>['batch', 'tap btn.save'],
          <String>['serve', '--allow-legacy-run'],
          <String>['live'],
          <String>['explore', '--once'],
          <String>['record', 'list'],
          <String>['replay', 'session.json'],
        ]) {
          final result = await _capture(arguments);
          expect(result.exitCode, 1, reason: '$arguments');
          expect(
            '${result.stdout}\n${result.stderr}',
            contains('agent_session_required'),
            reason: '$arguments',
          );
        }

        expect(connectionAttempts, 0);
      });
    },
  );

  test('lifecycle, diagnostics, and manual evidence stay public', () async {
    await _withTemporaryWorkspace(() async {
      for (final arguments in const <List<String>>[
        <String>['status'],
        <String>['doctor'],
        <String>['logs', '--summary'],
        <String>['evidence'],
      ]) {
        final result = await _capture(arguments);
        expect(result.exitCode, 0, reason: '$arguments: ${result.stderr}');
        expect(
          '${result.stdout}\n${result.stderr}',
          isNot(contains('agent_session_required')),
          reason: '$arguments',
        );
      }

      for (final arguments in const <List<String>>[
        <String>['screenshot'],
        <String>['crop', 'btn.save'],
        <String>['annotations', 'list'],
      ]) {
        final result = await _capture(arguments);
        expect(result.exitCode, 1, reason: '$arguments');
        expect(
          '${result.stdout}\n${result.stderr}',
          isNot(contains('agent_session_required')),
          reason: '$arguments',
        );
      }
    });
  });
}

Future<_CapturedRun> _capture(List<String> arguments) async {
  final capturedOut = _CapturedStdout();
  final capturedErr = _CapturedStdout();
  late final int exitCode;
  await IOOverrides.runZoned(
    () async {
      exitCode = await FlutterScoutCli().run(arguments);
    },
    stdout: () => capturedOut,
    stderr: () => capturedErr,
  );
  return _CapturedRun(exitCode, capturedOut.text, capturedErr.text);
}

Future<void> _withTemporaryWorkspace(Future<void> Function() body) async {
  final previous = Directory.current;
  final previousRegistry = FlutterScoutCli.debugRegistryPathOverride;
  final temporary = await Directory.systemTemp.createTemp(
    'flutter_scout_agent_cutover_',
  );
  try {
    Directory.current = temporary;
    FlutterScoutCli.debugRegistryPathOverride = p.join(
      temporary.path,
      'registry.json',
    );
    await body();
  } finally {
    FlutterScoutCli.debugRegistryPathOverride = previousRegistry;
    Directory.current = previous;
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  }
}

class _CapturedRun {
  const _CapturedRun(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;
}

class _CapturedStdout implements Stdout {
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
