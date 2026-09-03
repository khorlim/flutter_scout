import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'public_contract_support.dart';

void main() {
  final packageRoot = Directory.current.absolute.path;
  late Directory temporary;
  late Directory previousDirectory;
  String? previousRegistry;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('scout_single_json_');
    previousDirectory = Directory.current;
    previousRegistry = FlutterScoutCli.debugRegistryPathOverride;
    Directory.current = temporary;
    FlutterScoutCli.debugRegistryPathOverride = p.join(
      temporary.path,
      'registry.json',
    );
  });

  tearDown(() async {
    FlutterScoutCli.debugEventJournalAfterHeadCommitHook = null;
    FlutterScoutCli.debugRegistryPathOverride = previousRegistry;
    Directory.current = previousDirectory;
    await temporary.delete(recursive: true);
  });

  test(
    'success is one compact complete envelope and mode does not leak',
    () async {
      final cli = FlutterScoutCli();
      final single = await _capture(cli, ['--single-json', 'version']);
      expect(single.code, 0);
      expect(single.err, isEmpty);
      final result = _singleEnvelope(single.out);
      expect(result['ok'], isTrue);
      expect(result['version'], FlutterScoutCli.packageVersion);

      final ordinary = await _capture(cli, ['version']);
      expect(ordinary.code, 0);
      expect(ordinary.out.split('\n').length, greaterThan(2));
      final original = jsonDecode(ordinary.out) as Map;
      expect(result.keys, unorderedEquals(original.keys));
      expect(result['capabilities'], original['capabilities']);

      final events = File(
        '.flutter_scout/events.jsonl',
      ).readAsLinesSync().map(jsonDecode).whereType<Map>();
      expect(events.every((row) => row['status'] == 'completed'), isTrue);
    },
  );

  test(
    'early and command failures move to stdout only when opted in',
    () async {
      final cli = FlutterScoutCli();
      for (final args in <List<String>>[
        [],
        ['--app', 'missing-json-session', 'inspect'],
        ['--idempotency-key'],
        ['unknown-scout-command'],
        ['serve'],
        ['explore', '--once'],
      ]) {
        final failure = await _capture(cli, ['--single-json', ...args]);
        expect(
          failure.code,
          args.contains('unknown-scout-command') ? 64 : 1,
          reason: '$args',
        );
        expect(failure.err, isEmpty, reason: '$args');
        expect(_singleEnvelope(failure.out)['ok'], isFalse);
      }
      final ordinary = await _capture(cli, ['unknown-scout-command']);
      expect(ordinary.code, 64);
      expect(ordinary.out, isEmpty);
      expect((jsonDecode(ordinary.err) as Map)['ok'], isFalse);
    },
  );

  test(
    'subprocess failure preserves nonzero process exit and final JSON',
    () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=${p.join(packageRoot, '.dart_tool', 'package_config.json')}',
        p.join(packageRoot, 'bin', 'flutter_scout.dart'),
        '--single-json',
        'unknown-scout-command',
      ], workingDirectory: temporary.path);
      expect(result.exitCode, 64);
      expect(result.stderr, isEmpty);
      expect(_singleEnvelope(result.stdout.toString())['ok'], isFalse);
    },
    // The subprocess compiles the actual entrypoint; this is an exit/stream
    // contract check, not a Dart compiler performance assertion.
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'late evidence failure replaces success without dropping either',
    () async {
      var writes = 0;
      FlutterScoutCli.debugEventJournalAfterHeadCommitHook = () {
        if (++writes == 2) throw StateError('simulated completion failure');
      };
      final result = await _capture(FlutterScoutCli(), [
        '--single-json',
        'version',
      ]);
      expect(result.code, 1);
      final failure = _singleEnvelope(result.out);
      expect(failure['ok'], isFalse);
      expect(
        failure['structuredError'],
        containsPair('code', 'command_evidence_completion_failed'),
      );
      final earlier = _singleEnvelope(result.err);
      expect(earlier['ok'], isTrue);
      expect(earlier['commandId'], failure['commandId']);
    },
  );

  for (final single in [false, true]) {
    test(
      'long ensure retains live redacted progress, single-json=$single',
      () async {
        // A VM that accepts the socket but never answers getVM exercises the
        // real five-second command heartbeat and ensure's stdout progress path.
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <WebSocket>[];
        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          sockets.add(socket);
          socket.listen((_) {});
        });
        try {
          const secret = 'single-json-capability-secret';
          final uri = 'ws://127.0.0.1:${server.port}/$secret/ws';
          final capturedOut = _CapturedStream();
          final capturedErr = _CapturedStream();
          var sawLiveHeartbeat = false;
          capturedErr.onWrite = (text) {
            final row = jsonDecode(text) as Map;
            if (row['stage'] == 'command_running') {
              sawLiveHeartbeat = true;
              if (single) expect(capturedOut.text, isEmpty);
            }
          };
          final code = await IOOverrides.runZoned(
            () => FlutterScoutCli().run([
              if (single) '--single-json',
              'ensure',
              '--debug-url',
              uri,
            ]),
            stdout: () => capturedOut,
            stderr: () => capturedErr,
          );
          expect(code, 1); // No device was requested, so it cannot launch.
          expect(sawLiveHeartbeat, isTrue);
          final out = capturedOut.text;
          final err = capturedErr.text;
          expect('$out$err', isNot(contains(secret)));
          final diagnostics = err
              .split('\n')
              .where((line) => line.isNotEmpty)
              .map(jsonDecode)
              .cast<Map>();
          expect(
            diagnostics.any((row) => row['messageType'] == 'warning'),
            isTrue,
          );
          expect(
            diagnostics.any((row) => row['stage'] == 'command_running'),
            isTrue,
          );
          if (single) {
            final finalResponse = _singleEnvelope(out);
            expect(finalResponse['ok'], isFalse);
            expect(
              finalResponse['structuredError'],
              containsPair('code', 'missing_device'),
            );
            final progress = diagnostics.where(
              (row) => row['messageType'] == 'heartbeat',
            );
            expect(
              progress.any((row) => row['stage'] == 'discover_vm_service'),
              isTrue,
            );
            expect(progress.map((row) => row['commandId']).toSet(), {
              finalResponse['commandId'],
            });
            expect(capturedOut.writes, 1);
          } else {
            // The default stream's heartbeat JSONL is intentionally unchanged.
            expect(() => jsonDecode(out), throwsFormatException);
            final progress = out
                .split('\n')
                .where((line) => line.isNotEmpty)
                .map(jsonDecode)
                .cast<Map>();
            expect(
              progress.every((row) => row['messageType'] == 'heartbeat'),
              isTrue,
            );
            expect(diagnostics.last['ok'], isFalse);
          }
        } finally {
          for (final socket in sockets) {
            await socket.close();
          }
          await server.close(force: true);
        }
      },
    );
  }

  test('explicit help remains prose without dispatching', () async {
    final result = await _capture(FlutterScoutCli(), [
      '--single-json',
      'ensure',
      '--help',
    ]);
    expect(result.code, 0);
    expect(result.out, contains('Flutter Scout'));
    expect(result.err, isEmpty);
    expect(Directory('.flutter_scout').existsSync(), isFalse);
  });

  test('verbose batch keeps intermediate responses off final stdout', () async {
    final result = await _capture(FlutterScoutCli(), [
      '--single-json',
      'batch',
      'inspect --brief; inspect --brief',
      '--keep-going',
      '--verbose',
    ]);
    expect(result.code, 1); // No VM is attached in this isolated workspace.
    final finalResponse = _singleEnvelope(result.out);
    expect(finalResponse['commandName'], 'batch');
    expect(finalResponse['ok'], isFalse);
    final diagnostics = result.err
        .split('\n')
        .where((line) => line.isNotEmpty)
        .map(jsonDecode)
        .cast<Map>();
    expect(
      diagnostics.any((row) => row['stage'] == 'batch_step_started'),
      isTrue,
    );
    expect(diagnostics.any((row) => row['ok'] == false), isTrue);
  });
}

Map<String, dynamic> _singleEnvelope(String text) {
  expect(text.split('\n'), hasLength(2));
  final envelope = jsonDecode(text) as Map<String, dynamic>;
  canonicalCliEnvelope(envelope); // Required identity, safety, outcome, bounds.
  expect(envelope['messageType'], 'response');
  expect(utf8.encode(text).length, lessThanOrEqualTo(4 * 1024 * 1024 + 1));
  return envelope;
}

Future<({int code, String out, String err})> _capture(
  FlutterScoutCli cli,
  List<String> args,
) async {
  final out = _CapturedStream();
  final err = _CapturedStream();
  final code = await IOOverrides.runZoned(
    () => cli.run(args),
    stdout: () => out,
    stderr: () => err,
  );
  return (code: code, out: out.text, err: err.text);
}

class _CapturedStream implements Stdout {
  final _buffer = StringBuffer();
  int writes = 0;
  void Function(String)? onWrite;
  String get text => _buffer.toString();

  @override
  void writeln([Object? object = '']) {
    writes++;
    _buffer.writeln(object);
    onWrite?.call('$object');
  }

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  Future<void> flush() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
