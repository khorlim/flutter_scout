import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help')) {
    stdout.writeln(_usage);
    return;
  }

  try {
    final options = _parse(arguments);
    final catalogRoot = Directory(options.catalogPath);
    final descriptorFile = File(
      options.descriptorPath ?? '${catalogRoot.path}/corpus_descriptor.v1.json',
    );
    final policyFile = options.policyPath == null
        ? File.fromUri(
            Platform.script.resolve('../policies/gold_conformance.v1.json'),
          )
        : File(options.policyPath!);

    final sets = await const CatalogLoader().load(catalogRoot);
    final catalogReport = const CatalogValidator().validate(sets);
    final descriptor = CorpusDescriptor.fromJson(
      jsonDecode(
        utf8.decode(
          await readStableBoundedRegularFile(
            descriptorFile,
            maximumBytes: 4 * 1024 * 1024,
          ),
          allowMalformed: false,
        ),
      ),
    );
    final policy = CorpusPolicy.fromJson(
      jsonDecode(
        utf8.decode(
          await readStableBoundedRegularFile(
            policyFile,
            maximumBytes: 1024 * 1024,
          ),
          allowMalformed: false,
        ),
      ),
    );
    final corpusReport = const CorpusValidator().validate(
      catalog: sets,
      descriptor: descriptor,
      policy: policy,
    );
    final valid = catalogReport.isValid && corpusReport.isValid;
    final releaseEligible = valid && corpusReport.releaseEligible;
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'ok': valid,
        'releaseEligible': releaseEligible,
        'releaseEligibilityRequired': options.requireReleaseEligible,
        'policyId': policy.policyId,
        'inputDigests': {
          'catalogSha256': computeCatalogSha256(sets),
          'descriptorSha256': jsonSha256(descriptor.toJson()),
          'policySha256': jsonSha256(policy.toJson()),
        },
        'catalog': catalogReport.toJson(),
        'corpus': corpusReport.toJson(),
      }),
    );
    if (!valid) {
      exitCode = 1;
    } else if (options.requireReleaseEligible && !releaseEligible) {
      exitCode = 2;
    }
  } on FormatException catch (error) {
    stderr.writeln(
      jsonEncode({
        'ok': false,
        'releaseEligible': false,
        'error': {'code': 'invalid_input', 'message': error.message},
      }),
    );
    exitCode = 1;
  } on ArgumentError catch (error) {
    stderr.writeln(
      jsonEncode({
        'ok': false,
        'releaseEligible': false,
        'error': {'code': 'invalid_input', 'message': error.message},
      }),
    );
    exitCode = 1;
  } on FileSystemException catch (error) {
    stderr.writeln(
      jsonEncode({
        'ok': false,
        'releaseEligible': false,
        'error': {
          'code': 'filesystem',
          'message': error.message,
          if (error.path != null) 'path': error.path,
        },
      }),
    );
    exitCode = 1;
  }
}

class _Options {
  const _Options({
    required this.catalogPath,
    required this.requireReleaseEligible,
    this.descriptorPath,
    this.policyPath,
  });

  final String catalogPath;
  final String? descriptorPath;
  final String? policyPath;
  final bool requireReleaseEligible;
}

_Options _parse(List<String> arguments) {
  if (arguments.length == 1 && !arguments.single.startsWith('--')) {
    return _Options(
      catalogPath: arguments.single,
      requireReleaseEligible: false,
    );
  }
  String? catalog;
  String? descriptor;
  String? policy;
  var requireReleaseEligible = false;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--require-release-eligible') {
      if (requireReleaseEligible) {
        throw const FormatException(
          '`--require-release-eligible` was supplied more than once.',
        );
      }
      requireReleaseEligible = true;
      continue;
    }
    if (argument != '--catalog' &&
        argument != '--descriptor' &&
        argument != '--policy') {
      throw FormatException('Unknown argument `$argument`.\n$_usage');
    }
    if (index + 1 >= arguments.length) {
      throw FormatException('Missing value for `$argument`.\n$_usage');
    }
    final value = arguments[++index];
    if (value.startsWith('--') || value.trim().isEmpty) {
      throw FormatException('Invalid value for `$argument`.\n$_usage');
    }
    switch (argument) {
      case '--catalog':
        if (catalog != null) {
          throw const FormatException(
            '`--catalog` was supplied more than once.',
          );
        }
        catalog = value;
      case '--descriptor':
        if (descriptor != null) {
          throw const FormatException(
            '`--descriptor` was supplied more than once.',
          );
        }
        descriptor = value;
      case '--policy':
        if (policy != null) {
          throw const FormatException(
            '`--policy` was supplied more than once.',
          );
        }
        policy = value;
    }
  }
  if (catalog == null) throw FormatException('Missing `--catalog`.\n$_usage');
  return _Options(
    catalogPath: catalog,
    descriptorPath: descriptor,
    policyPath: policy,
    requireReleaseEligible: requireReleaseEligible,
  );
}

const _usage = '''
Validate a Flutter Scout evaluation catalog and its corpus descriptor:
  dart run bin/validate_catalog.dart CATALOG_ROOT
  dart run bin/validate_catalog.dart --catalog CATALOG_ROOT [--descriptor FILE] [--policy FILE] [--require-release-eligible]

The default descriptor is CATALOG_ROOT/corpus_descriptor.v1.json. The default
policy is policies/gold_conformance.v1.json. Structural invalidity exits 1.
`--require-release-eligible` exits 2 when any corpus release blocker remains.
''';
