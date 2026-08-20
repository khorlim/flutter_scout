import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('structured process output has no raw serializer bypass', () {
    final sourceRoot = Directory(p.join(Directory.current.path, 'lib', 'src'));
    final rawJsonWrite = RegExp(
      r'(?:stdout|stderr)\.writeln\(\s*jsonEncode\((?!\s*_sanitizeForSerialization)',
      multiLine: true,
    );
    final rawPrettyWrite = RegExp(
      r'(?:stdout|stderr)\.writeln\(\s*(?:const\s+)?JsonEncoder',
      multiLine: true,
    );
    final bypasses = <String>[];
    for (final file
        in sourceRoot
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      for (final match in <RegExp>[rawJsonWrite, rawPrettyWrite]) {
        if (match.hasMatch(source)) {
          bypasses.add(p.relative(file.path, from: Directory.current.path));
        }
      }
    }
    expect(
      bypasses,
      isEmpty,
      reason:
          'Structured stdout/stderr must use _printJson or explicitly wrap '
          '_sanitizeForSerialization: $bypasses',
    );
  });

  test(
    'adversarial corpus never enters CLI journals, exports, evidence, or argv',
    () async {
      final packageRoot = Directory.current.absolute.path;
      final corpus = _PrivacyCorpus.load();
      final secrets = corpus.secrets;
      final temp = await Directory.systemTemp.createTemp(
        'scout_adversarial_cli_privacy_',
      );
      try {
        final cli = FlutterScoutCli();
        _withSynchronousCwd(temp.path, () {
          for (var index = 0; index < secrets.length; index++) {
            cli.debugRecordAction(<String, Object?>{
              'cmd': 'input',
              'target': 'field.corpus_${index.toString().padLeft(3, '0')}',
              'value': secrets[index],
            });
          }
          cli.debugRecordAction(<String, Object?>{
            'cmd': 'fill',
            'values': jsonEncode(<String, String>{
              for (var index = 0; index < secrets.length; index++)
                'field.fill_${index.toString().padLeft(3, '0')}':
                    secrets[index],
            }),
          });
        });

        final sessionFile = File(
          p.join(temp.path, '.flutter_scout', 'session.json'),
        );
        final session = jsonDecode(sessionFile.readAsStringSync()) as List;
        expect(session, hasLength(secrets.length + 1));
        for (final raw in session) {
          final action = (raw as Map).cast<String, Object?>();
          expect(action['_redacted'], 'true');
          expect(action['_redactionPolicy'], 'source');
          if (action['cmd'] == 'input') {
            expect(action['value'], startsWith(' VAR:'));
            expect(action['_redactedFields'], <String>['value']);
          } else {
            expect(
              (action['values'] as Map).values,
              everyElement(startsWith(' VAR:')),
            );
          }
        }

        final sanitizedDiagnostics = cli.debugSanitizeSerialization(<
          String,
          Object?
        >{
          'stdout': <String>[
            for (final secret in secrets)
              'Authorization: Bearer $secret\n|FORGED_RECORD|',
          ],
          'stderr': <String>[
            for (final secret in secrets)
              jsonEncode(<String, String>{'privateValue': secret}),
          ],
          'encodedEchoes': <String>[
            for (final secret in secrets)
              for (final encoded in _secretVariants(secret))
                'encoded::$encoded::end',
            for (final secret in secrets)
              'upper-hex::${utf8.encode(secret).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}::end',
          ],
          'heartbeat': <String, Object?>{
            'stage': 'dispatch',
            'progress': secrets.join('\n|EVENT|'),
          },
        }, sensitiveValues: secrets);
        _expectLeakFree(
          sanitizedDiagnostics,
          secrets,
          surface: 'serialization guard',
        );
        _expectSerializedStringsAreSingleRecord(sanitizedDiagnostics);
        expect(jsonEncode(sanitizedDiagnostics), contains('<redacted>'));

        _withSynchronousCwd(temp.path, () {
          cli.debugAppendEventStrict(
            (cli.debugSanitizeSerialization(<String, Object?>{
                      'schemaVersion': 1,
                      'type': 'adversarial_privacy_probe',
                      'commandId': 'privacy-corpus',
                      'diagnostics': <String>[
                        for (final secret in secrets) 'echo::$secret',
                      ],
                    }, sensitiveValues: secrets)
                    as Map)
                .cast<String, Object?>(),
          );
        });

        final outputs = <_ProcessCapture>[];
        final ingressDirectory = Directory(p.join(temp.path, 'private-input'))
          ..createSync();
        final ingressFile = File(p.join(ingressDirectory.path, 'value.txt'))
          ..writeAsStringSync(secrets.join('\n'));
        if (!Platform.isWindows) {
          Process.runSync('/bin/chmod', <String>['700', ingressDirectory.path]);
          Process.runSync('/bin/chmod', <String>['600', ingressFile.path]);
          expect(FileStat.statSync(ingressDirectory.path).mode & 0x3f, 0);
          expect(FileStat.statSync(ingressFile.path).mode & 0x3f, 0);
        }
        final inputArguments = <String>[
          '--packages=${p.join(packageRoot, '.dart_tool', 'package_config.json')}',
          p.join(packageRoot, 'bin', 'flutter_scout.dart'),
          'input',
          '--target',
          'field.private_input',
          '--file',
          ingressFile.path,
        ];
        _expectArgvLeakFree(inputArguments, secrets);
        outputs.add(
          await _runCli(
            packageRoot: packageRoot,
            workingDirectory: temp.path,
            args: <String>[
              'input',
              '--target',
              'field.private_input',
              '--file',
              ingressFile.path,
            ],
          ),
        );
        expect(outputs.last.exitCode, isNot(0));
        ingressFile.deleteSync();
        ingressDirectory.deleteSync();

        final fillIngressDirectory = Directory(
          p.join(temp.path, 'private-fill-input'),
        )..createSync();
        final fillIngressFile =
            File(p.join(fillIngressDirectory.path, 'values.json'))
              ..writeAsStringSync(
                jsonEncode(<String, String>{
                  for (var index = 0; index < secrets.length; index++)
                    'field.fill_${index.toString().padLeft(3, '0')}':
                        secrets[index],
                }),
              );
        _makeOwnerOnly(fillIngressDirectory, fillIngressFile);
        final fillArguments = <String>[
          '--packages=${p.join(packageRoot, '.dart_tool', 'package_config.json')}',
          p.join(packageRoot, 'bin', 'flutter_scout.dart'),
          'fill',
          '--file',
          fillIngressFile.path,
        ];
        _expectArgvLeakFree(fillArguments, secrets);
        outputs.add(
          await _runCli(
            packageRoot: packageRoot,
            workingDirectory: temp.path,
            args: <String>['fill', '--file', fillIngressFile.path],
          ),
        );
        expect(outputs.last.exitCode, isNot(0));
        fillIngressFile.deleteSync();
        fillIngressDirectory.deleteSync();

        outputs.add(
          await _runCli(
            packageRoot: packageRoot,
            workingDirectory: temp.path,
            args: const <String>['input', '--stdin', '--target', 'field.stdin'],
            protectedStdin: secrets.join('\n'),
          ),
        );
        expect(outputs.last.exitCode, isNot(0));
        outputs.add(
          await _runCli(
            packageRoot: packageRoot,
            workingDirectory: temp.path,
            args: const <String>['fill', '--stdin'],
            protectedStdin: jsonEncode(<String, String>{
              for (var index = 0; index < secrets.length; index++)
                'field.stdin_${index.toString().padLeft(3, '0')}':
                    secrets[index],
            }),
          ),
        );
        expect(outputs.last.exitCode, isNot(0));

        final vmCredential =
            'ws://127.0.0.1:43123/SCOUT_PRIVATE_VM_CREDENTIAL_918273/ws';
        final uriSecrets = <String>[...secrets, vmCredential];
        final listenerSpec = _withSynchronousCwd(
          temp.path,
          () => cli.debugVmLogListenerLaunchSpec(
            vmUri: vmCredential,
            logFile: p.join(temp.path, '.flutter_scout', 'vm.log'),
            ownerPid: pid,
          ),
        );
        final listenerArguments = (listenerSpec['arguments'] as List)
            .cast<String>();
        _expectArgvLeakFree(listenerArguments, uriSecrets);
        expect(listenerArguments, contains('--vm-uri-file'));
        expect(listenerArguments, isNot(contains('--vm-uri')));
        final uriFile = File(listenerSpec['uriFile']! as String);
        expect(uriFile.readAsStringSync(), vmCredential);
        if (!Platform.isWindows) {
          expect(FileStat.statSync(uriFile.path).mode & 0x3f, 0);
          expect(FileStat.statSync(uriFile.parent.path).mode & 0x3f, 0);
        }
        uriFile.deleteSync();

        outputs.add(
          await _runCli(
            packageRoot: packageRoot,
            workingDirectory: temp.path,
            args: <String>[
              'record',
              'save-last',
              'privacy-corpus',
              '--last',
              '${secrets.length + 1}',
              '--feature',
              'security',
            ],
          ),
        );
        expect(outputs.last.exitCode, 0, reason: outputs.last.stderr);

        final recordingExport = p.join(temp.path, 'privacy-corpus.json');
        outputs.add(
          await _runCli(
            packageRoot: packageRoot,
            workingDirectory: temp.path,
            args: <String>[
              'record',
              'export',
              'privacy-corpus',
              '--feature',
              'security',
              '--out',
              recordingExport,
            ],
          ),
        );
        expect(outputs.last.exitCode, 0, reason: outputs.last.stderr);

        final batchExport = p.join(temp.path, 'privacy-corpus.scout');
        outputs.add(
          await _runCli(
            packageRoot: packageRoot,
            workingDirectory: temp.path,
            args: <String>['export-batch', '--output', batchExport],
          ),
        );
        expect(outputs.last.exitCode, 0, reason: outputs.last.stderr);

        outputs.add(
          await _runCli(
            packageRoot: packageRoot,
            workingDirectory: temp.path,
            args: <String>[
              'record',
              'show',
              'privacy-corpus',
              '--feature',
              'security',
              '--steps',
              '--transcript',
            ],
          ),
        );
        expect(outputs.last.exitCode, 0, reason: outputs.last.stderr);

        outputs.add(
          await _runCli(
            packageRoot: packageRoot,
            workingDirectory: temp.path,
            args: <String>['replay', recordingExport],
          ),
        );
        expect(outputs.last.exitCode, isNot(0));
        expect(outputs.last.combined, contains('missing_var'));

        final variableDirectory = Directory(
          p.join(temp.path, 'private-replay-vars'),
        )..createSync();
        final variableValues = <String, String>{
          for (
            var index = 0;
            index < secrets.length;
            index++
          ) ...<String, String>{
            'field.corpus_${index.toString().padLeft(3, '0')}': secrets[index],
            'field.fill_${index.toString().padLeft(3, '0')}': secrets[index],
          },
        };
        final variableFile = File(p.join(variableDirectory.path, 'vars.json'))
          ..writeAsStringSync(jsonEncode(variableValues));
        _makeOwnerOnly(variableDirectory, variableFile);
        for (final protectedRun in <List<String>>[
          <String>['replay', recordingExport, '--var-file', variableFile.path],
          <String>[
            'batch',
            '--file',
            batchExport,
            '--var-file',
            variableFile.path,
          ],
          <String>[
            'record',
            'run',
            'privacy-corpus',
            '--feature',
            'security',
            '--var-file',
            variableFile.path,
          ],
        ]) {
          _expectArgvLeakFree(protectedRun, secrets);
          outputs.add(
            await _runCli(
              packageRoot: packageRoot,
              workingDirectory: temp.path,
              args: protectedRun,
            ),
          );
          expect(outputs.last.exitCode, isNot(0));
        }
        outputs.add(
          await _runCli(
            packageRoot: packageRoot,
            workingDirectory: temp.path,
            args: <String>['replay', recordingExport, '--var-stdin'],
            protectedStdin: jsonEncode(variableValues),
          ),
        );
        expect(outputs.last.exitCode, isNot(0));
        variableFile.deleteSync();
        variableDirectory.deleteSync();

        final evidenceDirectory = p.join(temp.path, 'privacy-evidence');
        outputs.add(
          await _runCli(
            packageRoot: packageRoot,
            workingDirectory: temp.path,
            args: <String>[
              'evidence',
              '--output',
              evidenceDirectory,
              '--last',
              '20',
              '--audit',
            ],
          ),
        );
        expect(outputs.last.exitCode, 0, reason: outputs.last.stderr);

        const structuredVmToken =
            'SCOUT_PRIVATE_STATUS_DOCTOR_VM_TOKEN_546372819';
        const structuredTailToken = 'SCOUT_PRIVATE_LAUNCH_TAIL_TOKEN_192837465';
        uriSecrets
          ..add(structuredVmToken)
          ..add(structuredTailToken);
        final structuredVmUri = 'ws://127.0.0.1:1/$structuredVmToken/ws';
        for (final command in <List<String>>[
          const <String>['doctor'],
          const <String>['status'],
        ]) {
          _withSynchronousCwd(
            temp.path,
            () => cli.debugAtomicSessionWrite('vm_uri.txt', structuredVmUri),
          );
          outputs.add(
            await _runCli(
              packageRoot: packageRoot,
              workingDirectory: temp.path,
              args: command,
            ),
          );
          expect(outputs.last.exitCode, 0, reason: outputs.last.stderr);
          _expectLeakFree(outputs.last.combined, <String>[
            structuredVmToken,
            structuredVmUri,
          ], surface: '${command.first} structured output');
        }
        final launchEnvelope = cli.debugSanitizeSerialization(<String, Object?>{
          'launched': false,
          'vmServiceUri': structuredVmUri,
          'tailLogLines': <String>[
            'Authorization: Bearer $structuredTailToken\r\n'
                '|FORGED_LAUNCH_RECORD|\tsecond-column',
            'Cookie: session=$structuredTailToken\u2028forged-unicode-line',
          ],
        });
        _expectLeakFree(launchEnvelope, <String>[
          structuredVmToken,
          structuredVmUri,
          structuredTailToken,
        ], surface: 'launch structured output envelope');
        _expectSerializedStringsAreSingleRecord(launchEnvelope);
        final vmUriArtifact = File(
          p.join(temp.path, '.flutter_scout', 'vm_uri.txt'),
        );
        if (vmUriArtifact.existsSync()) vmUriArtifact.deleteSync();

        final combinedProcessOutput = <String>[
          for (final output in outputs) output.combined,
        ].join('\n');
        _expectLeakFree(
          combinedProcessOutput,
          uriSecrets,
          surface: 'CLI stdout and stderr',
        );
        _expectDirectoryLeakFree(temp, uriSecrets);

        final coverage =
            jsonDecode(
                  File(
                    p.join(
                      packageRoot,
                      '..',
                      '..',
                      'security',
                      'adversarial_privacy_coverage.json',
                    ),
                  ).readAsStringSync(),
                )
                as Map;
        final ingress = coverage['protectedIngress'] as Map;
        final controls = coverage['artifactControls'] as Map;
        expect(ingress['inputFile'], 'implemented');
        expect(ingress.values, everyElement('implemented'));
        expect(controls.values, everyElement('implemented'));
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

T _withSynchronousCwd<T>(String path, T Function() operation) {
  final previous = Directory.current;
  try {
    Directory.current = path;
    return operation();
  } finally {
    Directory.current = previous;
  }
}

class _ProcessCapture {
  const _ProcessCapture({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  String get combined => '$stdout\n$stderr';
}

Future<_ProcessCapture> _runCli({
  required String packageRoot,
  required String workingDirectory,
  required List<String> args,
  String? protectedStdin,
}) async {
  final processArgs = <String>[
    '--packages=${p.join(packageRoot, '.dart_tool', 'package_config.json')}',
    p.join(packageRoot, 'bin', 'flutter_scout.dart'),
    ...args,
  ];
  final process = await Process.start(
    Platform.resolvedExecutable,
    processArgs,
    workingDirectory: workingDirectory,
  );
  final stdoutFuture = utf8.decoder.bind(process.stdout).join();
  final stderrFuture = utf8.decoder.bind(process.stderr).join();
  if (protectedStdin != null) {
    process.stdin.add(utf8.encode(protectedStdin));
  }
  await process.stdin.close();
  final exitCode = await process.exitCode;
  return _ProcessCapture(
    exitCode: exitCode,
    stdout: await stdoutFuture,
    stderr: await stderrFuture,
  );
}

void _makeOwnerOnly(Directory directory, File file) {
  if (Platform.isWindows) return;
  Process.runSync('/bin/chmod', <String>['700', directory.path]);
  Process.runSync('/bin/chmod', <String>['600', file.path]);
  expect(FileStat.statSync(directory.path).mode & 0x3f, 0);
  expect(FileStat.statSync(file.path).mode & 0x3f, 0);
}

class _PrivacyCorpus {
  const _PrivacyCorpus(this.secrets);

  final List<String> secrets;

  static _PrivacyCorpus load() {
    final file = File(
      p.join(
        Directory.current.path,
        '..',
        '..',
        'security',
        'adversarial_privacy_corpus.json',
      ),
    );
    expect(file.existsSync(), isTrue, reason: file.path);
    final root = jsonDecode(file.readAsStringSync()) as Map;
    expect(root['schemaVersion'], 1);
    final seed = root['seed']! as String;
    final categories = (root['categories']! as List).cast<Map>();
    final tricks = (root['payloadTricks']! as List).cast<String>();
    final secrets = <String>[];
    for (
      var categoryIndex = 0;
      categoryIndex < categories.length;
      categoryIndex++
    ) {
      final category = categories[categoryIndex];
      for (var trickIndex = 0; trickIndex < tricks.length; trickIndex++) {
        final paddingLength = (categoryIndex * 7 + trickIndex * 3) % 17;
        final padding = List<String>.filled(paddingLength, 'x').join();
        secrets.add(
          'SCOUT_PRIVATE_${seed}_${categoryIndex.toString().padLeft(2, '0')}_'
          '${trickIndex.toString().padLeft(2, '0')}_${category['id']}_${padding}_'
          '${_decodeCorpusEscapes(tricks[trickIndex])}_PRIVATE_END',
        );
      }
    }
    expect(secrets.toSet(), hasLength(secrets.length));
    return _PrivacyCorpus(secrets);
  }
}

String _decodeCorpusEscapes(String value) => value
    .replaceAll(r'\u0000', '\u0000')
    .replaceAll(r'\u001f', '\u001f')
    .replaceAll(r'\u001b', '\u001b')
    .replaceAll(r'\u2028', '\u2028')
    .replaceAll(r'\u2029', '\u2029')
    .replaceAll(r'\r', '\r')
    .replaceAll(r'\n', '\n')
    .replaceAll(r'\t', '\t')
    .replaceAll(r'\"', '"')
    .replaceAll(r'\\', '\\');

Set<String> _secretVariants(String secret) {
  final jsonString = jsonEncode(secret);
  return <String>{
    secret,
    jsonString,
    if (jsonString.length >= 2) jsonString.substring(1, jsonString.length - 1),
    Uri.encodeComponent(secret),
    base64.encode(utf8.encode(secret)),
    base64Url.encode(utf8.encode(secret)),
    utf8
        .encode(secret)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(),
  }..removeWhere((variant) => variant.isEmpty);
}

void _expectArgvLeakFree(List<String> arguments, Iterable<String> secrets) {
  final argv = arguments.join('\u0000');
  _expectLeakFree(argv, secrets, surface: 'process argv');
}

void _expectLeakFree(
  Object? value,
  Iterable<String> secrets, {
  required String surface,
}) {
  final serialized = value is String ? value : jsonEncode(value);
  for (final secret in secrets) {
    for (final variant in _secretVariants(secret)) {
      expect(
        serialized.contains(variant),
        isFalse,
        reason:
            '$surface leaked a plaintext or encoded representation of a '
            '${secret.length}-code-unit secret',
      );
    }
  }
}

void _expectSerializedStringsAreSingleRecord(Object? value) {
  void visit(Object? child) {
    if (child is Map) {
      for (final nested in child.values) {
        visit(nested);
      }
    } else if (child is Iterable) {
      for (final nested in child) {
        visit(nested);
      }
    } else if (child is String) {
      expect(
        RegExp(r'[\u0000-\u001f\u007f-\u009f\u2028\u2029]').hasMatch(child),
        isFalse,
        reason: 'serialized diagnostic contains a raw record delimiter: $child',
      );
    }
  }

  visit(value);
}

void _expectDirectoryLeakFree(Directory directory, Iterable<String> secrets) {
  final variants = <List<int>>[
    for (final secret in secrets)
      for (final variant in _secretVariants(secret)) utf8.encode(variant),
  ];
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) continue;
    final bytes = entity.readAsBytesSync();
    for (final needle in variants) {
      expect(
        _containsBytes(bytes, needle),
        isFalse,
        reason: 'secret representation leaked into ${entity.path}',
      );
    }
  }
}

bool _containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    var match = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (haystack[start + offset] != needle[offset]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
