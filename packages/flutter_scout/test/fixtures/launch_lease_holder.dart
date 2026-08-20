import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('expected one session-directory argument');
    exitCode = 64;
    return;
  }

  final cli = FlutterScoutCli();
  await cli.debugWithLaunchLease<void>(
    sessionDirectory: args.single,
    project: Directory.current.path,
    device: 'lease-test-device',
    name: 'lease-holder',
    body: (lease) async {
      stdout.writeln(jsonEncode(lease));
      await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
    },
  );
}
