import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('top-level help advertises every public CLI command', () async {
    final packageRoot = Directory.current.absolute.path;
    final contract =
        jsonDecode(
              File(
                p.join(
                  packageRoot,
                  '..',
                  '..',
                  'protocol',
                  'schemas',
                  'v1',
                  'public-cli-commands.json',
                ),
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final commands = (contract['commands'] as Map<String, dynamic>).keys;

    final result = await Process.run(Platform.resolvedExecutable, <String>[
      '--packages=${p.join(packageRoot, '.dart_tool', 'package_config.json')}',
      p.join(packageRoot, 'bin', 'flutter_scout.dart'),
      'help',
    ], workingDirectory: packageRoot);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final helpLines = result.stdout
        .toString()
        .split('\n')
        .map((line) => line.trimLeft())
        .where((line) => line.startsWith('flutter-scout '));
    for (final command in commands) {
      expect(
        helpLines.any((line) {
          final usage = line.substring('flutter-scout '.length);
          return usage == command ||
              usage.startsWith('$command ') ||
              usage.contains('| $command');
        }),
        isTrue,
        reason: 'help must advertise public command `$command`',
      );
    }
  });
}
