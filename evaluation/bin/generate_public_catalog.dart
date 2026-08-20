import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1 || arguments.first == '--help') {
    stderr.writeln(
      'Usage: dart run bin/generate_public_catalog.dart <empty-output-root>',
    );
    exitCode = 64;
    return;
  }

  try {
    final root = Directory(arguments.single);
    const generator = PublicAuthoringCatalogGenerator();
    await generator.write(root);
    final generated = generator.generate();
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'ok': true,
        'publicFixturesRunnable': true,
        'fixtureRevision': publicFixtureRevision,
        'releaseEligible': false,
        'output': root.absolute.path,
        'templateCount': generated.descriptor.templates.length,
        'taskCount': generated.catalog.publicDevelopment.length,
        'missingExternalAssets': const [
          'private_validation_catalog',
          'frozen_hidden_release_catalog',
          'two_real_application_integrations',
        ],
      }),
    );
  } on FileSystemException catch (error) {
    stderr.writeln(
      jsonEncode({
        'ok': false,
        'error': {'code': 'filesystem', 'message': error.message},
      }),
    );
    exitCode = 1;
  }
}
