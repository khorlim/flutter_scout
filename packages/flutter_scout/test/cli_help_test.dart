import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('top-level help advertises the cutover public CLI surface', () async {
    final packageRoot = Directory.current.absolute.path;
    final result = await Process.run(Platform.resolvedExecutable, <String>[
      '--packages=${p.join(packageRoot, '.dart_tool', 'package_config.json')}',
      p.join(packageRoot, 'bin', 'flutter_scout.dart'),
      'help',
    ], workingDirectory: packageRoot);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final help = result.stdout.toString();
    for (final command in const <String>[
      'ensure',
      'launch',
      'attach',
      'status',
      'doctor',
      'devices',
      'apps',
      'reload',
      'restart',
      'stop',
      'screenshot',
      'crop',
      'logs',
      'health',
      'evidence',
      'annotations',
      'agent',
    ]) {
      expect(help, contains(command), reason: 'missing public `$command`');
    }
    expect(help, contains('Agent protocol 2'));
    expect(help, contains('were removed'));
    expect(help, contains('no compatibility switch or automatic fallback'));
  });
}
