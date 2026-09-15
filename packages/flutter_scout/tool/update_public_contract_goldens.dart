import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
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
    p.join(
      packageRoot,
      'test',
      'goldens',
      'public-contract-envelopes.v2.sha256.json',
    ),
  );
  final current = buildPublicContractGoldens(packageRoot);
  final digest = <String, Object?>{
    'schemaVersion': current['schemaVersion'],
    'protocolVersion': current['protocolVersion'],
    'artifactKind': current['artifactKind'],
    'commandCount': (current['commands']! as List).length,
    'errorCount': (current['errors']! as List).length,
    'sha256': crypto.sha256
        .convert(utf8.encode(jsonEncode(current)))
        .toString(),
  };
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(prettyContractJson(digest), flush: true);
  stdout.writeln(output.path);
}
