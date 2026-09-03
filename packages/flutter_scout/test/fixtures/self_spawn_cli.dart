import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';

// Uses the production launch spec and command dispatcher in source, Pub-style
// JIT snapshots, and native executables without starting Flutter or launchd.
Future<void> main(List<String> args) async {
  final cli = FlutterScoutCli();
  if (args.isEmpty) return; // JIT snapshot training invocation.
  if (args.first == '--probe-plist') {
    stdout.write(
      cli.debugLaunchdRunnerPlist(
        label: 'dev.flutter-scout.runner.compiled-test',
        configFile: args[1],
        outputFile: args[2],
      ),
    );
    return;
  }
  if (args.first == '--probe-listener') {
    stdout.writeln(
      jsonEncode(
        cli.debugVmLogListenerLaunchSpec(
          vmUri: 'ws://127.0.0.1:12345/COMPILED_LISTENER_SENTINEL/ws',
          logFile: args[1],
          ownerPid: pid,
        ),
      ),
    );
    return;
  }
  exitCode = await cli.run(args);
}
