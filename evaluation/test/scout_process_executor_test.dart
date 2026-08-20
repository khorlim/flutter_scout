import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test('process executor passes arguments literally without a shell', () async {
    final temporary = await createPrivateTestDirectory(
      'flutter_scout_process_executor_',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final script = File('${temporary.path}/echo.dart');
    await script.writeAsString('''
import 'dart:convert';
import 'dart:io';
void main(List<String> arguments) {
  stdout.write(jsonEncode(arguments));
}
''');
    final executor = ProcessScoutCommandExecutor(
      workingDirectory: temporary,
      executable: Platform.resolvedExecutable,
      executableArguments: <String>[script.path],
    );

    final result = await executor.execute(
      arguments: const <String>[
        'input',
        'field.supplier_name',
        r'literal; $(touch should-not-run)',
      ],
      timeout: const Duration(seconds: 2),
    );

    expect(result.succeeded, isTrue);
    expect(jsonDecode(result.stdout), <String>[
      'input',
      'field.supplier_name',
      r'literal; $(touch should-not-run)',
    ]);
  });

  test('process executor kills a command at its action deadline', () async {
    final temporary = await createPrivateTestDirectory(
      'flutter_scout_process_executor_',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final script = File('${temporary.path}/wait.dart');
    await script.writeAsString('''
import 'dart:async';
Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 5));
}
''');
    final executor = ProcessScoutCommandExecutor(
      workingDirectory: temporary,
      executable: Platform.resolvedExecutable,
      executableArguments: <String>[script.path],
    );

    final result = await executor.execute(
      arguments: const <String>['wait', 'stable'],
      timeout: const Duration(milliseconds: 100),
    );

    expect(result.timedOut, isTrue);
    expect(result.exitCode, 124);
    expect(result.elapsedMs, lessThan(2000));
  });

  test('attach keeps the VM capability URI out of argv and evidence', () async {
    if (Platform.isWindows) return;
    final temporary = await createPrivateTestDirectory(
      'flutter_scout_process_executor_',
    );
    addTearDown(() => temporary.delete(recursive: true));
    const vmUri = 'ws://127.0.0.1:8181/PRIVATE_VM_TOKEN/ws';
    final script = File('${temporary.path}/protected_attach.dart');
    await script.writeAsString('''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> arguments) async {
  final file = File(arguments[2]);
  final mode = (await file.stat()).mode & 0x1ff;
  final value = await file.readAsString();
  stdout.write(jsonEncode({
    'arguments': arguments.take(2).toList(),
    'mode': mode,
    'valueMatches': value == '$vmUri',
    'path': file.path,
  }));
}
''');
    final executor = ProcessScoutCommandExecutor(
      workingDirectory: temporary,
      executable: Platform.resolvedExecutable,
      executableArguments: <String>[script.path],
    );

    final result = await executor.attach(
      vmServiceUri: vmUri,
      timeout: const Duration(seconds: 2),
    );

    expect(result.succeeded, isTrue);
    final observed = jsonDecode(result.stdout) as Map<String, Object?>;
    expect(observed['arguments'], <String>['attach', '--debug-url-file']);
    expect(observed['mode'], 0x180);
    expect(observed['valueMatches'], isTrue);
    expect(File(observed['path']! as String).existsSync(), isFalse);
    expect(result.arguments, <String>[
      'attach',
      '--debug-url-file',
      '<protected-owner-only-file>',
    ]);
    expect(
      jsonEncode(result.toToolEvent()),
      isNot(contains('PRIVATE_VM_TOKEN')),
    );
  });
}
