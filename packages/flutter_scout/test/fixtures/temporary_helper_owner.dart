import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter_scout/flutter_scout.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: temporary_helper_owner.dart <project> <helper>');
    exitCode = 64;
    return;
  }
  Directory.current = args[0];
  FlutterScoutCli.debugTemporaryHelperPubGetOverride = (project) async {
    final pubspec = File(p.join(project, 'pubspec.yaml')).readAsStringSync();
    final helperMatch = RegExp(
      r"flutter_scout_helper:\s*\n\s+path:\s*'([^']+)'",
    ).firstMatch(pubspec);
    final helperActive = helperMatch != null;
    final config = File(p.join(project, '.dart_tool', 'package_config.json'));
    config.parent.createSync(recursive: true);
    config.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'configVersion': 2,
        'packages': helperMatch == null
            ? const <Object?>[]
            : <Object?>[
                <String, Object?>{
                  'name': 'flutter_scout_helper',
                  'rootUri': Uri.directory(helperMatch.group(1)!).toString(),
                  'packageUri': 'lib/',
                  'languageVersion': '3.12',
                },
              ],
      }),
      flush: true,
    );
    File(p.join(project, 'pubspec.lock')).writeAsStringSync(
      helperActive
          ? 'packages:\n  flutter_scout_helper: tool\n'
          : 'packages:\n  cleanup_output: tool\n',
      flush: true,
    );
    return ProcessResult(42, 0, 'resolved', '');
  };
  await FlutterScoutCli().debugPrepareTemporaryHelper(
    project: args[0],
    helperPath: args[1],
  );
}
