import 'dart:convert';
import 'dart:io';

import 'digests.dart';
import 'episode_result.dart';
import 'failure.dart';
import 'input_io.dart';
import 'json_support.dart';

const int benchmarkEpisodeSchemaVersion = 1;

class BenchmarkInputException implements Exception {
  BenchmarkInputException(Iterable<String> issues)
    : issues = List<String>.unmodifiable(issues);

  final List<String> issues;

  @override
  String toString() => 'Invalid benchmark input: ${issues.join(' ')}';
}

class BenchmarkEpisodeEnvelope {
  BenchmarkEpisodeEnvelope({
    required this.configSha256,
    required this.scheduleSha256,
    required this.pairId,
    required this.repetition,
    required this.variantSeed,
    required this.repetitionSeed,
    required this.conditionOrder,
    required this.freshResetPerformed,
    required this.result,
  }) {
    validateIdentifier(pairId, 'pairId');
    _validateSha256(configSha256, 'configSha256');
    _validateSha256(scheduleSha256, 'scheduleSha256');
    if (repetition < 1 || conditionOrder < 1 || conditionOrder > 4) {
      throw ArgumentError('Repetition and condition order are out of range.');
    }
    if (repetitionSeed < 0) {
      throw ArgumentError.value(repetitionSeed, 'repetitionSeed');
    }
    if (!freshResetPerformed && result.validEpisode) {
      throw ArgumentError(
        'An episode without a fresh reset must be HARNESS_INVALID.',
      );
    }
    if (!freshResetPerformed &&
        result.failure?.category != FailureCategory.harnessInvalid) {
      throw ArgumentError(
        'Missing fresh reset requires a HARNESS_INVALID failure.',
      );
    }
  }

  final String configSha256;
  final String scheduleSha256;
  final String pairId;
  final int repetition;
  final int variantSeed;
  final int repetitionSeed;
  final int conditionOrder;
  final bool freshResetPerformed;
  final EpisodeResult result;

  factory BenchmarkEpisodeEnvelope.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$');
    rejectUnknownKeys(json, const {
      'schemaVersion',
      'configSha256',
      'scheduleSha256',
      'pairId',
      'repetition',
      'variantSeed',
      'repetitionSeed',
      'conditionOrder',
      'freshResetPerformed',
      'result',
    }, r'$');
    final version = expectJsonInt(json['schemaVersion'], r'$.schemaVersion');
    if (version != benchmarkEpisodeSchemaVersion) {
      throw FormatException(
        'Unsupported benchmark episode schemaVersion $version; expected '
        '$benchmarkEpisodeSchemaVersion.',
      );
    }
    return BenchmarkEpisodeEnvelope(
      configSha256: expectJsonString(json['configSha256'], r'$.configSha256'),
      scheduleSha256: expectJsonString(
        json['scheduleSha256'],
        r'$.scheduleSha256',
      ),
      pairId: expectJsonString(json['pairId'], r'$.pairId'),
      repetition: expectJsonInt(
        json['repetition'],
        r'$.repetition',
        minimum: 1,
      ),
      variantSeed: expectJsonInt(json['variantSeed'], r'$.variantSeed'),
      repetitionSeed: expectJsonInt(
        json['repetitionSeed'],
        r'$.repetitionSeed',
        minimum: 0,
      ),
      conditionOrder: expectJsonInt(
        json['conditionOrder'],
        r'$.conditionOrder',
        minimum: 1,
      ),
      freshResetPerformed: expectJsonBool(
        json['freshResetPerformed'],
        r'$.freshResetPerformed',
      ),
      result: EpisodeResult.fromJson(json['result']),
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': benchmarkEpisodeSchemaVersion,
    'configSha256': configSha256,
    'scheduleSha256': scheduleSha256,
    'pairId': pairId,
    'repetition': repetition,
    'variantSeed': variantSeed,
    'repetitionSeed': repetitionSeed,
    'conditionOrder': conditionOrder,
    'freshResetPerformed': freshResetPerformed,
    'result': result.toJson(),
  };
}

class LoadedBenchmarkEpisode {
  LoadedBenchmarkEpisode({
    required this.sourcePath,
    required this.fileSha256,
    required List<int> rawBytes,
    required this.envelope,
  }) : rawBytes = List<int>.unmodifiable(rawBytes);

  final String sourcePath;
  final String fileSha256;
  final List<int> rawBytes;
  final BenchmarkEpisodeEnvelope envelope;

  String get episodeId => envelope.result.episodeId;

  Map<String, Object?> inventoryJson() => {
    'episodeId': episodeId,
    'sourcePath': sourcePath,
    'fileSha256': fileSha256,
    'byteLength': rawBytes.length,
  };
}

class ImmutableEpisodeLoader {
  const ImmutableEpisodeLoader({
    this.maximumEpisodeFiles = 10000,
    this.maximumEpisodeBytes = 16 * 1024 * 1024,
    this.maximumArchiveBytes = 1024 * 1024 * 1024,
    this.maximumEntries = 20000,
  }) : assert(maximumEpisodeFiles > 0),
       assert(maximumEpisodeBytes > 0),
       assert(maximumArchiveBytes >= maximumEpisodeBytes),
       assert(maximumEntries >= maximumEpisodeFiles);

  final int maximumEpisodeFiles;
  final int maximumEpisodeBytes;
  final int maximumArchiveBytes;
  final int maximumEntries;

  Future<List<LoadedBenchmarkEpisode>> load(Directory directory) async {
    final directoryType = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (directoryType == FileSystemEntityType.notFound) {
      throw BenchmarkInputException([
        'Episode directory `${directory.path}` does not exist.',
      ]);
    }
    if (directoryType != FileSystemEntityType.directory) {
      throw BenchmarkInputException([
        'Episode archive `${directory.path}` must be a real directory.',
      ]);
    }
    final files = <File>[];
    var entryCount = 0;
    await for (final entry in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      entryCount += 1;
      if (entryCount > maximumEntries) {
        throw BenchmarkInputException([
          'Episode archive exceeds the $maximumEntries-entry traversal bound.',
        ]);
      }
      final type = await FileSystemEntity.type(entry.path, followLinks: false);
      if (type == FileSystemEntityType.directory) continue;
      if (type != FileSystemEntityType.file || !entry.path.endsWith('.json')) {
        throw BenchmarkInputException([
          'Episode archive entries must be regular `.json` files; found '
              '`${entry.path}`.',
        ]);
      }
      files.add(File(entry.path));
      if (files.length > maximumEpisodeFiles) {
        throw BenchmarkInputException([
          'Episode archive exceeds the '
              '$maximumEpisodeFiles-file bound.',
        ]);
      }
    }
    files.sort((first, second) => first.path.compareTo(second.path));
    final loaded = <LoadedBenchmarkEpisode>[];
    final issues = <String>[];
    final pathsByEpisodeId = <String, String>{};
    var totalBytes = 0;
    for (final file in files) {
      try {
        final bytes = await readStableBoundedRegularFile(
          file,
          maximumBytes: maximumEpisodeBytes,
        );
        totalBytes += bytes.length;
        if (totalBytes > maximumArchiveBytes) {
          throw EvaluationInputException(
            'Episode archive exceeds the '
            '$maximumArchiveBytes-byte aggregate bound.',
          );
        }
        final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
        final envelope = BenchmarkEpisodeEnvelope.fromJson(decoded);
        final previous = pathsByEpisodeId[envelope.result.episodeId];
        if (previous != null) {
          issues.add(
            'Duplicate episode id `${envelope.result.episodeId}` in `$previous` '
            'and `${file.path}`.',
          );
          continue;
        }
        pathsByEpisodeId[envelope.result.episodeId] = file.path;
        loaded.add(
          LoadedBenchmarkEpisode(
            sourcePath: file.path,
            fileSha256: sha256Bytes(bytes),
            rawBytes: bytes,
            envelope: envelope,
          ),
        );
      } on Object catch (error) {
        issues.add('Could not load `${file.path}`: $error');
      }
    }
    if (issues.isNotEmpty) throw BenchmarkInputException(issues);
    return List<LoadedBenchmarkEpisode>.unmodifiable(loaded);
  }
}

void _validateSha256(String value, String path) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw FormatException('$path must be a lowercase SHA-256 digest.');
  }
}
