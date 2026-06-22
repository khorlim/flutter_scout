import 'dart:io' as io;

import 'package:flutter_scout/flutter_scout.dart';

Future<void> main(List<String> arguments) async {
  io.exitCode = await FlutterScoutCli().run(arguments);
}
