import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  tearDown(() {
    FlutterScoutCli.debugVmServiceConnectObserver = null;
    FlutterScoutRetentionDebug.debugUseSessionDirectory(null);
  });

  test('VM service validation accepts only explicit loopback endpoints', () {
    final cli = FlutterScoutCli();
    final accepted = <String, String>{
      'http://127.0.0.1:8181/AUTH_TOKEN=/':
          'ws://127.0.0.1:8181/AUTH_TOKEN=/ws',
      'ws://127.42.9.8:1234/ws': 'ws://127.42.9.8:1234/ws',
      'https://localhost:4321/credential=/':
          'wss://localhost:4321/credential=/ws',
      'wss://[::1]:5353/secret=/ws': 'wss://[::1]:5353/secret=/ws',
    };
    for (final entry in accepted.entries) {
      final result = cli.debugValidateVmServiceUri(entry.key);
      expect(result['normalized'], entry.value, reason: entry.key);
      expect(
        result['endpoint'],
        containsPair('transportPolicy', 'loopback_only'),
      );
    }

    final rejected = <String, String>{
      'ws://example.com:8181/token=/ws': 'unsupported_vm_service_transport',
      'ws://192.168.1.7:8181/token=/ws': 'unsupported_vm_service_transport',
      'ws://[::ffff:127.0.0.1]:8181/token=/ws':
          'unsupported_vm_service_transport',
      'ws://localhost.:8181/token=/ws': 'unsupported_vm_service_transport',
      'ws://127.00.0.1:8181/token=/ws': 'unsupported_vm_service_transport',
      'ftp://127.0.0.1:8181/token': 'unsupported_vm_service_transport',
      'ws://user:pass@127.0.0.1:8181/token=/ws': 'invalid_vm_service_uri',
      'ws://127.0.0.1:8181/token=/ws#fragment': 'invalid_vm_service_uri',
      'ws://127.0.0.1/token=/ws': 'invalid_vm_service_uri',
      'ws://127.0.0.1:0/token=/ws': 'invalid_vm_service_uri',
      'ws://127.0.0.1:65536/token=/ws': 'invalid_vm_service_uri',
      'ws://127.0.0.1:not-a-port/token=/ws': 'invalid_vm_service_uri',
      'ws://127.0.0.1:8181/%ZZ/ws': 'invalid_vm_service_uri',
      'not a URI': 'invalid_vm_service_uri',
    };
    for (final entry in rejected.entries) {
      expect(
        () => cli.debugValidateVmServiceUri(entry.key),
        throwsA(
          isA<ScoutCliException>()
              .having((error) => error.code, 'code', entry.value)
              .having(
                (error) => error.details['egress'],
                'egress',
                'not_attempted',
              )
              .having(
                (error) => error.details['persistence'],
                'persistence',
                'not_written',
              ),
        ),
        reason: entry.key,
      );
    }
  });

  test(
    'rejected VM URI cannot reach connector or credential persistence',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'scout_vm_transport_rejected_',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      FlutterScoutRetentionDebug.debugUseSessionDirectory(
        p.join(temp.path, '.flutter_scout'),
      );
      final cli = FlutterScoutCli();
      var attempts = 0;
      FlutterScoutCli.debugVmServiceConnectObserver = (_) => attempts++;
      const remote = 'ws://203.0.113.9:8181/REMOTE_SECRET=/ws';

      await expectLater(
        cli.debugAttemptVmServiceConnection(remote),
        throwsA(
          isA<ScoutCliException>().having(
            (error) => error.code,
            'code',
            'unsupported_vm_service_transport',
          ),
        ),
      );
      expect(attempts, 0);
      expect(
        () => cli.debugPersistVmServiceUri(remote),
        throwsA(isA<ScoutCliException>()),
      );
      expect(File(cli.debugVmServiceCredentialPath).existsSync(), isFalse);
      expect(
        Directory(p.join(temp.path, '.flutter_scout')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'VM credential has one private store and endpoint-only metadata',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'scout_vm_transport_storage_',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      FlutterScoutRetentionDebug.debugUseSessionDirectory(
        p.join(temp.path, '.flutter_scout'),
      );
      final cli = FlutterScoutCli();
      const raw = 'http://127.0.0.1:8181/STORAGE_SECRET=/';
      cli.debugPersistVmServiceUri(raw);
      cli.debugWriteVmServiceSessionMetadata(raw);

      expect(
        File(cli.debugVmServiceCredentialPath).readAsStringSync(),
        'ws://127.0.0.1:8181/STORAGE_SECRET=/ws',
      );
      if (!Platform.isWindows) {
        expect(
          FileStat.statSync(cli.debugVmServiceCredentialPath).mode & 0x3f,
          0,
        );
      }
      final metadata = File(
        cli.debugVmServiceSessionMetadataPath,
      ).readAsStringSync();
      expect(metadata, isNot(contains('STORAGE_SECRET')));
      expect(metadata, isNot(contains('vmServiceUri')));
      expect(metadata, contains('vmServiceEndpoint'));
      expect(metadata, contains('credentialPresent'));
    },
  );

  test(
    'serialization replaces URI and encoded credentials with endpoint facts',
    () {
      final token = 'VM_SERIALIZATION_SECRET_42=';
      final raw = 'ws://127.0.0.1:8181/$token/ws?session=$token';
      final result = FlutterScoutCli()
          .debugSanitizeVmServicePayload(<String, Object?>{
            'vmServiceUri': raw,
            'echo': raw,
            'token': token,
            'uriEncoded': Uri.encodeComponent(raw),
            'base64': base64.encode(utf8.encode(raw)),
            'base64Url': base64Url.encode(utf8.encode(token)),
          });
      final encoded = jsonEncode(result);

      expect(result, isNot(contains('vmServiceUri')));
      expect(result['vmServiceEndpoint'], isA<Map>());
      for (final forbidden in <String>[
        raw,
        token,
        Uri.encodeComponent(raw),
        base64.encode(utf8.encode(raw)),
        base64Url.encode(utf8.encode(token)),
      ]) {
        expect(encoded, isNot(contains(forbidden)));
      }
    },
  );

  test(
    'protected attach/deeplink ingress and journals never expose credentials',
    () async {
      final packageRoot = Directory.current.absolute.path;
      final temp = await Directory.systemTemp.createTemp(
        'scout_uri_ingress_process_',
      );
      try {
        const vmToken = 'VM_FILE_SECRET_77=';
        const vmUri = 'ws://127.0.0.1:1/VM_FILE_SECRET_77=/ws';
        final vmFile = _privateFile(p.join(temp.path, 'vm.secret'), vmUri);
        final attach = await _runCli(packageRoot, temp.path, <String>[
          'attach',
          '--debug-url-file',
          vmFile.path,
        ]);
        expect(attach.exitCode, isNot(0));
        _expectNoVariants(attach.combined, vmUri, vmToken);
        expect(attach.combined, contains('VmServiceEndpoint'));
        expect(attach.combined, contains('credentialPresent'));
        vmFile.deleteSync();

        const stdinVmToken = 'VM_STDIN_SECRET_78=';
        const stdinVmUri = 'ws://127.0.0.1:1/VM_STDIN_SECRET_78=/ws';
        final stdinAttach = await _runCli(
          packageRoot,
          temp.path,
          const <String>['attach', '--debug-url-stdin'],
          stdinBytes: utf8.encode(stdinVmUri),
        );
        expect(stdinAttach.exitCode, isNot(0));
        _expectNoVariants(stdinAttach.combined, stdinVmUri, stdinVmToken);

        const legacyVmToken = 'VM_LEGACY_ARGV_SECRET_79=';
        const legacyVmUri = 'ws://127.0.0.1:1/VM_LEGACY_ARGV_SECRET_79=/ws';
        final legacyAttach = await _runCli(packageRoot, temp.path, const [
          'attach',
          '--debug-url',
          legacyVmUri,
        ]);
        expect(legacyAttach.exitCode, isNot(0));
        expect(legacyAttach.stderrText, contains('insecure_secret_source'));
        _expectNoVariants(legacyAttach.combined, legacyVmUri, legacyVmToken);

        const deepToken = 'DEEPLINK_STDIN_SECRET_88';
        const deepUrl =
            'scout-test://account/DEEPLINK_STDIN_SECRET_88?session=DEEPLINK_STDIN_SECRET_88';
        final deeplink = await _runCli(packageRoot, temp.path, const <String>[
          'deeplink',
          '--url-stdin',
        ], stdinBytes: utf8.encode(deepUrl));
        expect(deeplink.exitCode, isNot(0));
        _expectNoVariants(deeplink.combined, deepUrl, deepToken);

        const fileDeepToken = 'DEEPLINK_FILE_SECRET_89';
        const fileDeepUrl =
            'scout-test://account/DEEPLINK_FILE_SECRET_89?session=DEEPLINK_FILE_SECRET_89';
        final deepFile = _privateFile(
          p.join(temp.path, 'deeplink.secret'),
          fileDeepUrl,
        );
        final fileDeeplink = await _runCli(packageRoot, temp.path, <String>[
          'deeplink',
          '--url-file',
          deepFile.path,
        ]);
        expect(fileDeeplink.exitCode, isNot(0));
        _expectNoVariants(fileDeeplink.combined, fileDeepUrl, fileDeepToken);
        deepFile.deleteSync();

        final legacy = await _runCli(packageRoot, temp.path, <String>[
          'deeplink',
          deepUrl,
        ]);
        expect(legacy.stderrText, contains('insecure_secret_source'));
        _expectNoVariants(legacy.combined, deepUrl, deepToken);

        _expectTreeHasNoVariants(temp, const <String>[
          vmUri,
          vmToken,
          stdinVmUri,
          stdinVmToken,
          legacyVmUri,
          legacyVmToken,
          deepUrl,
          deepToken,
          fileDeepUrl,
          fileDeepToken,
        ]);
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'status doctor and rejected attach disclose no VM capability bytes',
    () async {
      final packageRoot = Directory.current.absolute.path;

      final rejectedRoot = await Directory.systemTemp.createTemp(
        'scout_vm_remote_attach_',
      );
      try {
        const remoteToken = 'REMOTE_VM_SECRET_101=';
        const remoteUri = 'ws://203.0.113.12:8181/REMOTE_VM_SECRET_101=/ws';
        final rejected = await _runCli(packageRoot, rejectedRoot.path, const [
          'attach',
          '--debug-url',
          remoteUri,
        ]);
        expect(rejected.exitCode, isNot(0));
        expect(rejected.combined, contains('unsupported_vm_service_transport'));
        _expectNoVariants(rejected.combined, remoteUri, remoteToken);
        expect(
          Directory(p.join(rejectedRoot.path, '.flutter_scout')).existsSync(),
          isFalse,
        );
      } finally {
        if (rejectedRoot.existsSync()) {
          rejectedRoot.deleteSync(recursive: true);
        }
      }

      final statusRoot = await Directory.systemTemp.createTemp(
        'scout_vm_status_doctor_',
      );
      try {
        final session = Directory(p.join(statusRoot.path, '.flutter_scout'))
          ..createSync();
        if (!Platform.isWindows) {
          final chmod = Process.runSync('/bin/chmod', <String>[
            '700',
            session.path,
          ]);
          expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
        }
        const token = 'STATUS_VM_SECRET_202=';
        const uri = 'ws://127.0.0.1:1/STATUS_VM_SECRET_202=/ws';
        _privateFile(p.join(session.path, 'vm_uri.txt'), uri);
        _privateFile(
          p.join(session.path, 'session_meta.json'),
          jsonEncode(<String, Object?>{
            'mode': 'attach_only',
            'state': 'ready',
            'runId': 'legacy-session-with-capability-url',
            'vmServiceUri': uri,
          }),
        );

        final status = await _runCli(packageRoot, statusRoot.path, const [
          'status',
        ]);
        _expectNoVariants(status.combined, uri, token);
        expect(
          File(p.join(session.path, 'session_meta.json')).readAsStringSync(),
          isNot(contains(token)),
        );
        _expectTreeHasNoVariants(statusRoot, const <String>[uri, token]);

        // Doctor may retain the single designated private capability file, but
        // its response, command journal, metadata, and every other file must be
        // endpoint-only/redacted.
        _privateFile(p.join(session.path, 'vm_uri.txt'), uri);
        final doctor = await _runCli(packageRoot, statusRoot.path, const [
          'doctor',
          '--project',
          '.',
        ]);
        _expectNoVariants(doctor.combined, uri, token);
        _expectTreeHasNoVariants(
          statusRoot,
          const <String>[uri, token],
          exceptRelativePaths: const <String>{'.flutter_scout/vm_uri.txt'},
        );
      } finally {
        if (statusRoot.existsSync()) statusRoot.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'Flutter worker hands off one private capability and redacts its log',
    () async {
      final packageRoot = Directory.current.absolute.path;
      final temp = await Directory.systemTemp.createTemp(
        'scout_vm_worker_handoff_',
      );
      try {
        final session = Directory(p.join(temp.path, '.flutter_scout'))
          ..createSync(recursive: true);
        final runDirectory = Directory(
          p.join(session.path, 'runs', 'worker-security-run'),
        )..createSync(recursive: true);
        if (!Platform.isWindows) {
          for (final directory in <Directory>[session, runDirectory]) {
            final chmod = Process.runSync('/bin/chmod', <String>[
              '700',
              directory.path,
            ]);
            expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
          }
        }
        const token = 'WORKER_VM_SECRET_303=';
        const raw = 'http://127.0.0.1:8181/WORKER_VM_SECRET_303=/';
        final logFile = p.join(runDirectory.path, 'logs.txt');
        final config = _privateFile(
          p.join(runDirectory.path, 'worker.json'),
          jsonEncode(<String, Object?>{
            'project': temp.path,
            'flutterExecutable': '/bin/sh',
            'flutterArgs': const <String>[
              '-c',
              "printf '%s\\n' 'A Dart VM Service is available at: $raw'",
            ],
            'logFile': logFile,
            'vmUriFile': p.join(session.path, 'vm_uri.txt'),
            'sessionDirectory': session.path,
            'runId': 'worker-security-run',
            'persistentConfig': false,
            'supervised': false,
          }),
        );

        final worker = await _runCli(packageRoot, temp.path, <String>[
          'flutter-run-worker',
          '--config',
          config.path,
        ]);
        expect(worker.exitCode, 0, reason: worker.combined);
        expect(
          File(p.join(session.path, 'vm_uri.txt')).readAsStringSync(),
          'ws://127.0.0.1:8181/WORKER_VM_SECRET_303=/ws',
        );
        final log = File(logFile).readAsStringSync();
        _expectNoVariants(log, raw, token);
        expect(log, contains('<redacted>'));
        _expectTreeHasNoVariants(
          temp,
          const <String>[raw, token],
          exceptRelativePaths: const <String>{'.flutter_scout/vm_uri.txt'},
        );
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
    onPlatform: const <String, dynamic>{
      'windows': Skip('uses /bin/sh as a deterministic fake Flutter tool'),
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('deeplink business URL is absent from durable receipt bytes', () async {
    final temp = await Directory.systemTemp.createTemp(
      'scout_deeplink_receipt_secret_',
    );
    addTearDown(() => temp.deleteSync(recursive: true));
    final session = p.join(temp.path, '.flutter_scout');
    FlutterScoutRetentionDebug.debugUseSessionDirectory(session);
    final cli = FlutterScoutCli()..debugEnsurePrivateStorage();
    cli.debugAtomicSessionWrite(
      'session_meta.json',
      jsonEncode(<String, Object?>{
        'mode': 'attach_only',
        'state': 'ready',
        'runId': 'deeplink-receipt-run',
      }),
    );
    const token = 'DEEPLINK_RECEIPT_SECRET_99';
    const url =
        'scout-test://account/DEEPLINK_RECEIPT_SECRET_99?token=DEEPLINK_RECEIPT_SECRET_99';
    final result = await cli.debugDurableLocalMutation(
      idempotencyKey: 'deeplink-receipt-key',
      method: 'process.adb.am_start',
      businessParams: const <String, String>{'url': url},
      dispatch: () async => <String, dynamic>{
        'ok': false,
        'dispatch': 'not_dispatched',
        'transport': 'failed',
      },
    );
    expect(result['dispatch'], 'not_dispatched');
    _expectTreeHasNoVariants(temp, const <String>[url, token]);
  });
}

class _CliCapture {
  const _CliCapture(this.exitCode, this.stdoutText, this.stderrText);

  final int exitCode;
  final String stdoutText;
  final String stderrText;

  String get combined => '$stdoutText\n$stderrText';
}

Future<_CliCapture> _runCli(
  String packageRoot,
  String workingDirectory,
  List<String> args, {
  List<int>? stdinBytes,
}) async {
  final executableArgs = <String>[
    '--packages=${p.join(packageRoot, '.dart_tool', 'package_config.json')}',
    p.join(packageRoot, 'bin', 'flutter_scout.dart'),
    ...args,
  ];
  if (stdinBytes == null) {
    final result = await Process.run(
      Platform.resolvedExecutable,
      executableArgs,
      workingDirectory: workingDirectory,
    );
    return _CliCapture(
      result.exitCode,
      result.stdout.toString(),
      result.stderr.toString(),
    );
  }
  final process = await Process.start(
    Platform.resolvedExecutable,
    executableArgs,
    workingDirectory: workingDirectory,
  );
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(stdinBytes);
  await process.stdin.close();
  final exitCode = await process.exitCode.timeout(const Duration(seconds: 30));
  return _CliCapture(exitCode, await stdoutFuture, await stderrFuture);
}

File _privateFile(String path, String value) {
  final file = File(path)..writeAsStringSync(value, flush: true);
  if (!Platform.isWindows) {
    final result = Process.runSync('/bin/chmod', <String>['600', path]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }
  return file;
}

void _expectNoVariants(String value, String full, String token) {
  for (final forbidden in <String>[
    full,
    token,
    Uri.encodeComponent(full),
    Uri.encodeComponent(token),
    base64.encode(utf8.encode(full)),
    base64.encode(utf8.encode(token)),
    base64Url.encode(utf8.encode(full)),
    base64Url.encode(utf8.encode(token)),
  ]) {
    expect(value, isNot(contains(forbidden)));
  }
}

void _expectTreeHasNoVariants(
  Directory root,
  List<String> secrets, {
  Set<String> exceptRelativePaths = const <String>{},
}) {
  final forbidden = <List<int>>[
    for (final secret in secrets) ...<List<int>>[
      utf8.encode(secret),
      utf8.encode(Uri.encodeComponent(secret)),
      utf8.encode(base64.encode(utf8.encode(secret))),
      utf8.encode(base64Url.encode(utf8.encode(secret))),
    ],
  ];
  final leaks = <String>[];
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final relative = p.relative(entity.path, from: root.path);
    if (exceptRelativePaths.contains(relative)) continue;
    final bytes = entity.readAsBytesSync();
    if (forbidden.any((needle) => _containsBytes(bytes, needle))) {
      leaks.add(relative);
    }
  }
  expect(leaks, isEmpty, reason: 'credential variants leaked into $leaks');
}

bool _containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    var matches = true;
    for (var index = 0; index < needle.length; index++) {
      if (haystack[start + index] != needle[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
