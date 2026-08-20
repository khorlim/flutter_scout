import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';

Future<void> main(List<String> arguments) async {
  Directory? workspace;
  try {
    final options = _parseOptions(arguments);
    final manifest = TaskManifest.fromJson(
      jsonDecode(await _readBounded(File(options['manifest']!), 1024 * 1024)),
    );
    final plan = ToolSimulatorPlan.fromJson(
      jsonDecode(await _readBounded(File(options['plan']!), 1024 * 1024)),
    );
    final capability = await _readEvaluatorCapability(
      File(options['oracle-config']!),
    );
    final vmServiceUri = await _readProtectedVmServiceUri(
      File(options['vm-uri-file']!),
    );
    final archiveDirectory = Directory(options['archive']!).absolute;
    workspace = await Directory.systemTemp.createTemp(
      'flutter_scout_tool_simulator_',
    );
    final runner = ToolSimulatorEpisodeRunner(
      oracleClient: VmServiceSupplierOracleClient(
        vmServiceUri: vmServiceUri,
        capability: capability,
      ),
      commandExecutor: ProcessScoutCommandExecutor(
        workingDirectory: workspace,
        executable: options['scout-executable'] ?? 'flutter-scout',
      ),
      archive: RawEpisodeArchive(archiveDirectory),
    );
    final run = await runner.run(
      manifest: manifest,
      episodeId: plan.episodeId,
      condition: plan.condition,
      vmServiceUri: vmServiceUri,
      planProvider: StaticToolSimulatorPlanProvider(plan),
    );
    stdout.writeln(
      jsonEncode(<String, Object?>{
        'ok': true,
        'episodeId': run.episode.episodeId,
        'validEpisode': run.episode.validEpisode,
        'passed': run.episode.passed,
        'failureCategory': run.episode.failure?.category.jsonName,
        'archivePath': run.archiveFile.absolute.path,
        'scope': 'public_tool_simulator_only',
        'releaseEligible': false,
      }),
    );
    exitCode = run.episode.passed ? 0 : 2;
  } on Object catch (error) {
    stderr.writeln(
      jsonEncode(<String, Object?>{
        'ok': false,
        'error': <String, Object?>{
          'code': 'tool_simulator_runner_failed',
          'type': error.runtimeType.toString(),
          'message':
              'The public tool-simulator episode could not be completed.',
        },
        'releaseEligible': false,
      }),
    );
    exitCode = 1;
  } finally {
    if (workspace != null && await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  }
}

Map<String, String> _parseOptions(List<String> arguments) {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    stdout.writeln('''
Run one public tool-simulator episode:
  dart run bin/run_tool_simulator_episode.dart \\
    --manifest MANIFEST.json --plan PLAN.json --vm-uri-file OWNER_ONLY_URI \\
    --oracle-config OWNER_ONLY.json --archive DIRECTORY \\
    [--scout-executable flutter-scout]
''');
    exit(0);
  }
  const allowed = <String>{
    'manifest',
    'plan',
    'vm-uri-file',
    'oracle-config',
    'archive',
    'scout-executable',
  };
  const required = <String>{
    'manifest',
    'plan',
    'vm-uri-file',
    'oracle-config',
    'archive',
  };
  final result = <String, String>{};
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (!argument.startsWith('--')) {
      throw const FormatException('Options must use --name value form.');
    }
    final name = argument.substring(2);
    if (!allowed.contains(name) || result.containsKey(name)) {
      throw const FormatException('Unknown or duplicate runner option.');
    }
    if (index + 1 >= arguments.length ||
        arguments[index + 1].startsWith('--')) {
      throw const FormatException('A runner option is missing its value.');
    }
    result[name] = arguments[++index];
  }
  if (!result.keys.toSet().containsAll(required)) {
    throw const FormatException('Required runner options are missing.');
  }
  return result;
}

Future<String> _readEvaluatorCapability(File file) async {
  final type = FileSystemEntity.typeSync(file.path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw const FileSystemException(
      'Evaluator configuration must be a regular, non-symlink file.',
    );
  }
  if (!Platform.isWindows) {
    final permissions = FileStat.statSync(file.path).mode & 0x1ff;
    if (permissions != 0x180) {
      throw const FileSystemException(
        'Evaluator configuration must have exact owner-only mode 0600.',
      );
    }
  }
  final decoded = jsonDecode(await _readBounded(file, 4096));
  if (decoded is! Map ||
      decoded.keys.toSet().difference(const <Object?>{
        'FLUTTER_SCOUT_EVALUATOR_ENABLED',
        'FLUTTER_SCOUT_EVALUATOR_TOKEN',
      }).isNotEmpty ||
      decoded.length != 2 ||
      decoded['FLUTTER_SCOUT_EVALUATOR_ENABLED'] != 'true') {
    throw const FormatException('Evaluator configuration is invalid.');
  }
  final capability = decoded['FLUTTER_SCOUT_EVALUATOR_TOKEN'];
  if (capability is! String ||
      capability.length < 32 ||
      capability.trim() != capability) {
    throw const FormatException('Evaluator capability is invalid.');
  }
  return capability;
}

Future<String> _readProtectedVmServiceUri(File file) async {
  _requireOwnerOnlyRegularFile(file, 'VM-service URI');
  final value = await _readBounded(file, 4096);
  if (value.isEmpty ||
      value.trim() != value ||
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw const FormatException(
      'VM-service URI file must contain one bounded printable URI.',
    );
  }
  return value;
}

void _requireOwnerOnlyRegularFile(File file, String label) {
  final type = FileSystemEntity.typeSync(file.path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw FileSystemException(
      '$label must be a regular, non-symlink file.',
      file.path,
    );
  }
  if (!Platform.isWindows) {
    final permissions = FileStat.statSync(file.path).mode & 0x1ff;
    if (permissions != 0x180) {
      throw FileSystemException(
        '$label must have exact owner-only mode 0600.',
        file.path,
      );
    }
  }
}

Future<String> _readBounded(File file, int maximumBytes) async {
  final bytes = await readStableBoundedRegularFile(
    file,
    maximumBytes: maximumBytes,
  );
  return utf8.decode(bytes, allowMalformed: false);
}
