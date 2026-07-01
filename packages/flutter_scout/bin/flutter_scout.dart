import 'dart:io' as io;

import 'package:flutter_scout/flutter_scout.dart';

Future<void> main(List<String> arguments) async {
  final code = await FlutterScoutCli().run(arguments);
  // Once the command has produced its result, exit promptly. Some paths (e.g. a
  // VM-service RPC that timed out against an unresponsive app) can leave a
  // half-open socket whose close handshake never completes, which would
  // otherwise keep the event loop alive and delay exit by ~30s even though the
  // result was already printed. Detached children (flutter run, log listener)
  // survive this exit.
  await io.stdout.flush();
  await io.stderr.flush();
  io.exit(code);
}
