import 'dart:io';

import 'package:path/path.dart' as p;

import '../test/public_contract_support.dart';

void main(List<String> arguments) {
  if (arguments.isNotEmpty) {
    stderr.writeln('Usage: dart run tool/update_public_contract_goldens.dart');
    exitCode = 64;
    return;
  }
  final packageRoot = Directory.current.path;
  final output = File(
    p.join(packageRoot, 'test', 'goldens', 'public-contract-envelopes.v1.json'),
  );
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(
    prettyContractJson(buildPublicContractGoldens(packageRoot)),
    flush: true,
  );
  stdout.writeln(output.path);
}
