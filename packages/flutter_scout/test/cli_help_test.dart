import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
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

  test('every public command has its own help', () async {
    final commands = FlutterScoutCli.debugCommandHelpOptions.keys;
    expect(
      commands,
      containsAll(const <String>[
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
      ]),
    );
    for (final command in commands) {
      for (final args in <List<String>>[
        [command, '--help'],
        ['help', command],
      ]) {
        final out = StringBuffer();
        final code = await IOOverrides.runZoned(
          () => FlutterScoutCli().run(args),
          stdout: () => _BufferStdout(out),
          stderr: () => _BufferStdout(StringBuffer()),
        );
        expect(code, 0, reason: '$args');
        expect(
          out.toString(),
          startsWith('Flutter Scout: $command\n'),
          reason: '$args must print command help, not the overview',
        );
        for (final option
            in FlutterScoutCli.debugCommandHelpOptions[command]!) {
          expect(out.toString(), contains(option), reason: '$args');
        }
      }
    }
  });

  test('documented command options match each command parser exactly', () {
    final source = Directory('lib/src')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');
    // Options parsed by the command but deliberately undocumented.
    const hidden = <String, Set<String>>{
      'stop': <String>{'quiet'},
    };
    final optionName = RegExp(r'--(?:\[no-\])?([a-z0-9][a-z0-9-]*)');
    final declared = RegExp(
      r'''add(?:Option|Flag|MultiOption)\(\s*'([a-z0-9-]+)'|(_addRendererOption)\(''',
    );
    var checked = 0;
    for (final entry in FlutterScoutCli.debugCommandHelpOptions.entries) {
      final signature = 'Future<int> _${entry.key}(List<String> args) async {';
      final start = source.indexOf(signature);
      if (start < 0) continue;
      final end = source.indexOf('.parse(', start);
      final next = source.indexOf('Future<int> _', start + signature.length);
      final parsed = <String>{};
      if (end > 0 && (next < 0 || end < next)) {
        for (final match in declared.allMatches(source.substring(start, end))) {
          parsed.add(match.group(1) ?? 'enable-impeller');
        }
      }
      final documented = <String>{
        for (final option in entry.value)
          for (final match in optionName.allMatches(option)) match.group(1)!,
      };
      expect(
        documented,
        parsed.difference(hidden[entry.key] ?? const <String>{}),
        reason: '`${entry.key}` help must list exactly its parser options',
      );
      checked++;
    }
    expect(checked, greaterThanOrEqualTo(14));
  });
}

final class _BufferStdout implements Stdout {
  _BufferStdout(this._buffer);

  final StringBuffer _buffer;

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
