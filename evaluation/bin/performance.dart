import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.isEmpty || arguments.first == '--help') {
      stdout.writeln(_usage);
      return;
    }
    final command = arguments.first;
    if (command != 'report' && command != 'config-digest') {
      throw FormatException('Unknown command `${arguments.first}`.\n$_usage');
    }
    final options = _parseOptions(arguments.skip(1).toList());
    _rejectExtra(
      options,
      command == 'report'
          ? const {'config', 'samples', 'output'}
          : const {'config'},
    );
    final configFile = File(_required(options, 'config'));
    final configBytes = await readStableBoundedRegularFile(
      configFile,
      maximumBytes: 1024 * 1024,
    );
    final config = PerformanceConfig.fromJson(
      jsonDecode(utf8.decode(configBytes, allowMalformed: false)),
    );
    if (command == 'config-digest') {
      stdout.writeln(
        jsonEncode({
          'schemaVersion': performanceConfigSchemaVersion,
          'benchmarkId': config.benchmarkId,
          'configSha256': config.sha256,
          'environmentSha256': config.environment.sha256,
          'ratificationStatus': config.thresholds.status.jsonName,
        }),
      );
      return;
    }
    final samples = await const ImmutablePerformanceSampleLoader().load(
      Directory(_required(options, 'samples')),
    );
    final report = const PerformanceReportBuilder().build(
      config: config,
      samples: samples,
    );
    await _emit(report.toJson(), options['output']);
    if (report.componentBlocked) exitCode = 2;
  } on Object catch (error) {
    stderr.writeln(
      jsonEncode({
        'ok': false,
        'errorType': error.runtimeType.toString(),
        'error': error.toString(),
      }),
    );
    exitCode = 64;
  }
}

Map<String, String> _parseOptions(List<String> arguments) {
  if (arguments.length.isOdd) {
    throw FormatException('Options must use `--name value`.\n$_usage');
  }
  final result = <String, String>{};
  for (var index = 0; index < arguments.length; index += 2) {
    final option = arguments[index];
    if (!option.startsWith('--')) {
      throw FormatException('Options must use `--name value`.\n$_usage');
    }
    final name = option.substring(2);
    if (name.isEmpty || result.containsKey(name)) {
      throw FormatException('Invalid or duplicate option `$option`.');
    }
    result[name] = arguments[index + 1];
  }
  return result;
}

String _required(Map<String, String> options, String name) {
  final value = options[name];
  if (value == null || value.trim().isEmpty) {
    throw FormatException('Missing required option `--$name`.\n$_usage');
  }
  return value;
}

void _rejectExtra(Map<String, String> options, Set<String> allowed) {
  final extra = options.keys.where((name) => !allowed.contains(name)).toList()
    ..sort();
  if (extra.isNotEmpty) {
    throw FormatException(
      'Unknown options: ${extra.map((name) => '--$name').join(', ')}.',
    );
  }
}

Future<void> _emit(Map<String, Object?> value, String? outputPath) async {
  final bytes = utf8.encode(
    '${const JsonEncoder.withIndent('  ').convert(value)}\n',
  );
  if (outputPath == null) {
    stdout.add(bytes);
    await stdout.flush();
    return;
  }
  final file = File(outputPath);
  try {
    await file.create(exclusive: true);
  } on FileSystemException {
    if (await file.exists()) {
      throw StateError(
        'Report `$outputPath` already exists and will not be overwritten.',
      );
    }
    rethrow;
  }
  await _setOwnerOnly(file);
  final handle = await file.open(mode: FileMode.writeOnly);
  try {
    await handle.writeFrom(bytes);
    await handle.flush();
  } finally {
    await handle.close();
  }
}

Future<void> _setOwnerOnly(File file) async {
  if (Platform.isWindows) return;
  final result = await Process.run('/bin/chmod', <String>['600', file.path]);
  if (result.exitCode != 0 || ((await file.stat()).mode & 0x1ff) != 0x180) {
    throw StateError('Could not make performance evidence owner-only.');
  }
}

const _usage = '''
Flutter Scout performance and observation non-interference evidence reporter

Fingerprint the canonical config and environment:
  dart run bin/performance.dart config-digest --config CONFIG.json

Validate a complete, immutable exact-byte sample archive and build a report:
  dart run bin/performance.dart report --config CONFIG.json --samples SAMPLES [--output REPORT.json]

There is no exclusion option. Every preregistered baseline and candidate sample
must be present. A constructed report never constitutes full release eligibility.
''';
