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
    final options = _parseOptions(arguments.skip(1).toList());
    final catalogPath = _required(options, 'catalog');
    final catalog = await const CatalogLoader().load(Directory(catalogPath));
    if (command == 'catalog-digest') {
      _rejectExtra(options, const {'catalog'});
      const CatalogValidator().validate(catalog).throwIfInvalid();
      stdout.writeln(computeCatalogSha256(catalog));
      return;
    }
    final configPath = _required(options, 'config');
    final config = BenchmarkConfig.fromJson(
      jsonDecode(
        utf8.decode(
          await readStableBoundedRegularFile(
            File(configPath),
            maximumBytes: 1024 * 1024,
          ),
          allowMalformed: false,
        ),
      ),
    );
    if (command == 'schedule') {
      _rejectExtra(options, const {'config', 'catalog', 'output'});
      final schedule = BenchmarkSchedule.generate(
        config: config,
        catalog: catalog,
      );
      await _emit(schedule.toJson(), options['output']);
      return;
    }
    if (command == 'report') {
      _rejectExtra(options, const {'config', 'catalog', 'episodes', 'output'});
      final episodePath = _required(options, 'episodes');
      final episodes = await const ImmutableEpisodeLoader().load(
        Directory(episodePath),
      );
      final report = const BenchmarkReportBuilder().build(
        config: config,
        catalog: catalog,
        episodes: episodes,
      );
      await _emit(report.toJson(), options['output']);
      if (report.safetyBlocked || report.invalidHarnessCount > 0) {
        exitCode = 2;
      }
      return;
    }
    throw FormatException('Unknown command `$command`.\n$_usage');
  } on Object catch (error) {
    stderr.writeln(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'ok': false, 'error': error.toString()}),
    );
    exitCode = 64;
  }
}

Map<String, String> _parseOptions(List<String> arguments) {
  final result = <String, String>{};
  for (var index = 0; index < arguments.length; index += 2) {
    final option = arguments[index];
    if (!option.startsWith('--') || index + 1 >= arguments.length) {
      throw FormatException('Options must use `--name value`.\n$_usage');
    }
    final name = option.substring(2);
    if (result.containsKey(name)) {
      throw FormatException('Option `--$name` was supplied more than once.');
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
  final extra = options.keys.where((key) => !allowed.contains(key)).toList()
    ..sort();
  if (extra.isNotEmpty) {
    throw FormatException(
      'Unknown options: ${extra.map((key) => '--$key').join(', ')}.',
    );
  }
}

Future<void> _emit(Map<String, Object?> json, String? outputPath) async {
  final bytes = utf8.encode(
    '${const JsonEncoder.withIndent('  ').convert(json)}\n',
  );
  if (outputPath == null) {
    stdout.add(bytes);
    await stdout.flush();
  } else {
    final file = File(outputPath);
    try {
      await file.create(exclusive: true);
    } on FileSystemException {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError(
          'Evidence `$outputPath` already exists and will not be overwritten.',
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
}

Future<void> _setOwnerOnly(File file) async {
  if (Platform.isWindows) return;
  final result = await Process.run('/bin/chmod', <String>['600', file.path]);
  if (result.exitCode != 0 || ((await file.stat()).mode & 0x1ff) != 0x180) {
    throw StateError('Could not make benchmark evidence owner-only.');
  }
}

const _usage = '''
Flutter Scout paired and controlled-comparison benchmark foundation

Fingerprint a validated catalog for `catalogSha256`:
  dart run bin/benchmark.dart catalog-digest --catalog CATALOG

Generate the deterministic execution schedule:
  dart run bin/benchmark.dart schedule --config CONFIG.json --catalog CATALOG [--output SCHEDULE.json]

Validate immutable raw episodes and produce a report:
  dart run bin/benchmark.dart report --config CONFIG.json --catalog CATALOG --episodes EPISODES [--output REPORT.json]

There is intentionally no exclusion option. Missing or mismatched episodes fail.
An optional config controlledComparison block schedules three or four roles;
current-versus-candidate remains the paired statistical comparison.
''';
