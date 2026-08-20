import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

part 'release_contract.dart';

const int releaseEvidenceFormatVersion = 1;

typedef ReleaseCommandRunner =
    Future<ReleaseProbeResult> Function(
      String executable,
      List<String> arguments,
      String workingDirectory,
    );

final class ReleaseProbeResult {
  const ReleaseProbeResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  String get combinedOutput => <String>[
    if (stdout.trim().isNotEmpty) stdout.trim(),
    if (stderr.trim().isNotEmpty) stderr.trim(),
  ].join('\n');
}

final class ReleaseArtifact {
  const ReleaseArtifact({required this.name, required this.file});

  final String name;
  final File file;
}

final class ReleaseEvidenceResult {
  const ReleaseEvidenceResult({
    required this.outputDirectory,
    required this.candidateCommit,
    required this.cleanWorktree,
    required this.files,
  });

  final Directory outputDirectory;
  final String candidateCommit;
  final bool cleanWorktree;
  final List<String> files;
}

final class ReleaseEvidenceVerification {
  const ReleaseEvidenceVerification(this.errors);

  final List<String> errors;

  bool get ok => errors.isEmpty;
}

final class ReleaseEvidenceGenerator {
  ReleaseEvidenceGenerator({
    required Directory repository,
    ReleaseCommandRunner? commandRunner,
    Map<String, String>? environment,
    String? operatingSystem,
    String? operatingSystemVersion,
    String? dartRuntimeVersion,
  }) : repository = Directory(_canonicalExistingDirectory(repository)),
       _commandRunner = commandRunner ?? runReleaseProbe,
       _environment = Map<String, String>.unmodifiable(
         environment ?? Platform.environment,
       ),
       _operatingSystem = operatingSystem ?? Platform.operatingSystem,
       _operatingSystemVersion =
           operatingSystemVersion ?? Platform.operatingSystemVersion,
       _dartRuntimeVersion = dartRuntimeVersion ?? Platform.version;

  final Directory repository;
  final ReleaseCommandRunner _commandRunner;
  final Map<String, String> _environment;
  final String _operatingSystem;
  final String _operatingSystemVersion;
  final String _dartRuntimeVersion;

  Future<ReleaseEvidenceResult> generate({
    required Directory outputDirectory,
    List<ReleaseArtifact> artifacts = const <ReleaseArtifact>[],
    int? sourceDateEpoch,
    bool allowDirty = false,
  }) async {
    _validateRepository();
    final output = Directory(_canonicalOutputDestination(outputDirectory));
    _validateOutputDirectory(output);
    final checkedArtifacts = _validateArtifacts(artifacts);

    final gitHead = await _requiredProbe('git', const <String>[
      'rev-parse',
      'HEAD',
    ]);
    final gitTree = await _requiredProbe('git', const <String>[
      'rev-parse',
      'HEAD^{tree}',
    ]);
    final gitStatus = await _requiredProbe('git', const <String>[
      'status',
      '--porcelain=v1',
      '--untracked-files=all',
    ]);
    final cleanWorktree = gitStatus.isEmpty;
    if (!cleanWorktree && !allowDirty) {
      throw StateError(
        'The release evidence generator refuses a dirty worktree. Commit or '
        'remove candidate changes, or use --allow-dirty only for a '
        'non-releasable diagnostic bundle.',
      );
    }
    final gitCommitEpoch = int.parse(
      await _requiredProbe('git', const <String>[
        'show',
        '-s',
        '--format=%ct',
        'HEAD',
      ]),
    );
    final timestamp = _resolveTimestamp(sourceDateEpoch, gitCommitEpoch);

    final probes = await Future.wait(<Future<ReleaseProbeResult>>[
      _commandRunner('dart', const <String>['--version'], repository.path),
      _commandRunner('flutter', const <String>[
        '--version',
        '--machine',
      ], repository.path),
      _commandRunner('uname', const <String>['-m'], repository.path),
    ]);

    final sourceFiles = _discoverSourceEvidenceFiles();
    final lockFiles = sourceFiles
        .where((file) => _baseName(file.path) == 'pubspec.lock')
        .toList(growable: false);
    final schemaFiles = sourceFiles
        .where((file) => _relativePath(file).startsWith('protocol/schemas/'))
        .toList(growable: false);

    final privatePermissionsEnforced =
        _operatingSystem == 'macos' || _operatingSystem == 'linux';
    _createOutputDirectory(
      output,
      privatePermissions: privatePermissionsEnforced,
    );

    final sourceDigests = <String, String>{
      for (final file in sourceFiles) _relativePath(file): sha256File(file),
    };
    final artifactDigests = <String, Map<String, Object>>{
      for (final artifact in checkedArtifacts)
        artifact.name: <String, Object>{
          'sha256': sha256File(artifact.file),
          'size': artifact.file.lengthSync(),
        },
    };
    final schemaDigests = <String, String>{
      for (final file in schemaFiles)
        _relativePath(file): sourceDigests[_relativePath(file)]!,
    };
    final schemaSetDigest = sha256Bytes(
      utf8.encode(
        schemaDigests.entries
            .map((entry) => '${entry.key}\u0000${entry.value}\n')
            .join(),
      ),
    );
    final sourceSetDigest = _releaseAggregateDigest(sourceDigests);

    final packageIdentities = <Map<String, Object?>>[];
    for (final file in sourceFiles.where(
      (candidate) => _baseName(candidate.path) == 'pubspec.yaml',
    )) {
      packageIdentities.add(_readPubspecIdentity(file));
    }
    packageIdentities.sort(
      (left, right) =>
          (left['path']! as String).compareTo(right['path']! as String),
    );

    final provenance = <String, Object?>{
      'evidenceFormatVersion': releaseEvidenceFormatVersion,
      'generatedAt': timestamp.$1.toIso8601String(),
      'timestampSource': timestamp.$2,
      'candidate': <String, Object?>{
        'commit': gitHead,
        'tree': gitTree,
        'cleanWorktree': cleanWorktree,
        'worktreeStatusEntryCount': _statusEntryCount(gitStatus),
        'worktreeStatusSha256': sha256Bytes(utf8.encode(gitStatus)),
      },
      'toolchain': <String, Object?>{
        'dart': _dartProvenance(probes[0]),
        'flutter': _flutterProvenance(probes[1]),
        'blockingFlutterPin': _readBlockingFlutterPin(),
      },
      'host': <String, Object?>{
        'operatingSystem': _operatingSystem,
        'operatingSystemVersion': _operatingSystemVersion,
        'architecture': probes[2].exitCode == 0
            ? probes[2].combinedOutput
            : null,
        'architectureCollectionError': probes[2].exitCode == 0
            ? null
            : _boundedProbeFailure(probes[2]),
      },
      'ci': _ciProvenance(),
      'packages': packageIdentities,
      'protocol': _readProtocolIdentity(),
      'protocolSchemas': <String, Object?>{
        'count': schemaDigests.length,
        'aggregateSha256': schemaSetDigest,
      },
      'artifacts': <String, Object?>{
        'count': artifactDigests.length,
        'provided': artifactDigests.keys.toList(growable: false),
        'missingReason': artifactDigests.isEmpty
            ? 'No --artifact arguments were supplied. This diagnostic bundle '
                  'does not contain release-artifact checksums.'
            : null,
      },
      'artifactProtection': <String, Object?>{
        'ownerOnlyPermissionsEnforced': privatePermissionsEnforced,
        'directoryMode': privatePermissionsEnforced ? '0700' : null,
        'fileMode': privatePermissionsEnforced ? '0600' : null,
        'missingReason': privatePermissionsEnforced
            ? null
            : 'Owner-only POSIX modes are not enforceable by this generator '
                  'on the current host.',
      },
      'generator': <String, Object?>{
        'path': 'tool/release/generate_release_evidence.dart',
        'sha256': sha256File(
          File(
            '${repository.path}/tool/release/generate_release_evidence.dart',
          ),
        ),
        'librarySha256': sha256File(
          File('${repository.path}/tool/release/release_evidence.dart'),
        ),
        'releaseContractLibrarySha256': sha256File(
          File('${repository.path}/tool/release/release_contract.dart'),
        ),
        'releaseContractCatalogSha256': sha256File(
          File('${repository.path}/$_releaseContractCatalogPath'),
        ),
        'offlineInputsOnly': true,
      },
    };

    final dependencyInventory = _buildDependencyInventory(
      lockFiles: lockFiles,
      generatedAt: timestamp.$1,
      candidateCommit: gitHead,
    );
    final schemaDocument = <String, Object?>{
      'schemaDigestFormatVersion': 1,
      'aggregateAlgorithm': 'SHA-256 over sorted path, NUL, digest, LF records',
      'aggregateSha256': schemaSetDigest,
      'schemas': schemaDigests,
    };
    final artifactsDocument = _buildReleaseArtifactDigestsDocument(
      candidateCommit: gitHead,
      artifactDigests: artifactDigests,
    );

    final releaseContracts = _buildReleaseContractDocuments(
      generator: this,
      sourceFiles: sourceFiles,
      schemaFiles: schemaFiles,
      packageIdentities: packageIdentities,
      artifactDigests: artifactDigests,
      dependencyInventory: dependencyInventory,
      protocolIdentity: provenance['protocol']! as Map<String, Object?>,
      candidateCommit: gitHead,
      candidateTree: gitTree,
      generatedAt: timestamp.$1,
      schemaSetDigest: schemaSetDigest,
      sourceSetDigest: sourceSetDigest,
    );

    final preSigningGenerated = <String, List<int>>{
      'provenance.json': _jsonBytes(provenance),
      'schema-digests.json': _jsonBytes(schemaDocument),
      'dependency-inventory.cdx.json': _jsonBytes(dependencyInventory),
      'dependency-sbom.cdx.json': _jsonBytes(releaseContracts.sbom),
      'provenance-statement.intoto.json': _jsonBytes(
        releaseContracts.provenanceStatement,
      ),
      'release-alignment.json': _jsonBytes(releaseContracts.alignment),
      'release-contract-catalog.json': _jsonBytes(releaseContracts.catalog),
      'release-schema-manifest.json': _jsonBytes(
        releaseContracts.schemaManifest,
      ),
      'rollback-plan.json': _jsonBytes(releaseContracts.rollbackPlan),
      'source-checksums.sha256': utf8.encode(_checksumLines(sourceDigests)),
      'artifact-checksums.sha256': utf8.encode(
        _checksumLines(<String, String>{
          for (final entry in artifactDigests.entries)
            entry.key: entry.value['sha256']! as String,
        }),
      ),
      'artifacts.json': _jsonBytes(artifactsDocument),
    };
    final signingContract = _buildSigningVerificationContract(
      candidateCommit: gitHead,
      boundEvidenceDigests: <String, String>{
        for (final entry in preSigningGenerated.entries)
          entry.key: sha256Bytes(entry.value),
      },
    );
    final generated = <String, List<int>>{
      ...preSigningGenerated,
      'signing-verification.json': _jsonBytes(signingContract),
    };
    for (final entry in generated.entries) {
      _writeAtomic(
        File('${output.path}/${entry.key}'),
        entry.value,
        privatePermissions: privatePermissionsEnforced,
      );
    }

    final manifest = <String, Object?>{
      'evidenceFormatVersion': releaseEvidenceFormatVersion,
      'candidateCommit': gitHead,
      'generatedAt': timestamp.$1.toIso8601String(),
      'evidenceFiles': <String, String>{
        for (final entry in generated.entries)
          entry.key: sha256Bytes(entry.value),
      },
    };
    final manifestBytes = _jsonBytes(manifest);
    _writeAtomic(
      File('${output.path}/manifest.json'),
      manifestBytes,
      privatePermissions: privatePermissionsEnforced,
    );
    _writeAtomic(
      File('${output.path}/manifest.sha256'),
      utf8.encode('${sha256Bytes(manifestBytes)}  manifest.json\n'),
      privatePermissions: privatePermissionsEnforced,
    );

    return ReleaseEvidenceResult(
      outputDirectory: output,
      candidateCommit: gitHead,
      cleanWorktree: cleanWorktree,
      files: <String>[...generated.keys, 'manifest.json', 'manifest.sha256'],
    );
  }

  Future<ReleaseEvidenceVerification> verify({
    required Directory evidenceDirectory,
    Map<String, File> artifacts = const <String, File>{},
  }) async {
    final errors = <String>[];
    final directory = Directory(_canonicalExistingDirectory(evidenceDirectory));
    if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return const ReleaseEvidenceVerification(<String>[
        'evidence path is missing, not a directory, or a symlink',
      ]);
    }
    final manifestFile = File('${directory.path}/manifest.json');
    if (FileSystemEntity.typeSync(manifestFile.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return const ReleaseEvidenceVerification(<String>[
        'manifest.json is missing',
      ]);
    }
    final manifestChecksum = File('${directory.path}/manifest.sha256');
    if (FileSystemEntity.typeSync(manifestChecksum.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return const ReleaseEvidenceVerification(<String>[
        'manifest.sha256 is missing',
      ]);
    }
    final expectedManifestLine = '${sha256File(manifestFile)}  manifest.json';
    if (manifestChecksum.readAsStringSync().trim() != expectedManifestLine) {
      return const ReleaseEvidenceVerification(<String>[
        'manifest.json checksum mismatch',
      ]);
    }
    Object? decoded;
    try {
      decoded = jsonDecode(manifestFile.readAsStringSync());
    } on FormatException catch (error) {
      return ReleaseEvidenceVerification(<String>[
        'manifest.json is invalid JSON: $error',
      ]);
    }
    if (decoded is! Map ||
        decoded['evidenceFormatVersion'] != releaseEvidenceFormatVersion ||
        decoded['evidenceFiles'] is! Map) {
      return const ReleaseEvidenceVerification(<String>[
        'manifest.json has an unsupported or incomplete contract',
      ]);
    }
    final evidenceFiles = decoded['evidenceFiles']! as Map;
    final allowedNames = <String>{'manifest.json', 'manifest.sha256'};
    for (final entry in evidenceFiles.entries) {
      final name = entry.key.toString();
      final expected = entry.value.toString();
      if (!_safeLogicalName(name)) {
        errors.add('manifest contains an unsafe evidence filename: $name');
        continue;
      }
      allowedNames.add(name);
      final file = File('${directory.path}/$name');
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        errors.add('$name is missing');
      } else if (sha256File(file) != expected) {
        errors.add('$name checksum mismatch');
      }
    }
    for (final entity in directory.listSync(followLinks: false)) {
      final name = _baseName(entity.path);
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (type != FileSystemEntityType.file) {
        errors.add('unexpected non-regular evidence entry: $name');
      } else if (!allowedNames.contains(name)) {
        errors.add('unexpected unmanifested evidence file: $name');
      }
    }

    _verifyChecksumFile(
      File('${directory.path}/source-checksums.sha256'),
      resolve: (name) => File('${repository.path}/$name'),
      errors: errors,
      label: 'source',
    );
    _verifyChecksumFile(
      File('${directory.path}/artifact-checksums.sha256'),
      resolve: (name) => artifacts[name],
      errors: errors,
      label: 'artifact',
      missingResolverIsError: true,
    );
    try {
      final provenanceFile = File('${directory.path}/provenance.json');
      final provenance = jsonDecode(provenanceFile.readAsStringSync());
      final candidate = provenance is Map ? provenance['candidate'] : null;
      final expectedCommit = candidate is Map
          ? candidate['commit']?.toString()
          : null;
      final currentCommit = await _requiredProbe('git', const <String>[
        'rev-parse',
        'HEAD',
      ]);
      if (expectedCommit == null || expectedCommit != currentCommit) {
        errors.add(
          'verification checkout commit does not match provenance candidate',
        );
      }
      final currentTree = await _requiredProbe('git', const <String>[
        'rev-parse',
        'HEAD^{tree}',
      ]);
      final currentStatus = await _requiredProbe('git', const <String>[
        'status',
        '--porcelain=v1',
        '--untracked-files=all',
      ]);
      if (currentStatus.isNotEmpty) {
        errors.add('verification checkout is dirty');
      }
      _verifyReleaseContractDocuments(
        generator: this,
        directory: directory,
        manifest: decoded,
        currentCommit: currentCommit,
        currentTree: currentTree,
        artifacts: artifacts,
        errors: errors,
      );
    } on Object catch (error) {
      errors.add('candidate provenance verification failed: $error');
    }
    return ReleaseEvidenceVerification(List<String>.unmodifiable(errors));
  }

  void _validateRepository() {
    if (!repository.existsSync()) {
      throw ArgumentError('Repository does not exist: ${repository.path}');
    }
    if (FileSystemEntity.typeSync('${repository.path}/.git') ==
        FileSystemEntityType.notFound) {
      throw ArgumentError('Not a Git worktree root: ${repository.path}');
    }
    for (final path in const <String>[
      'QUALITY_STANDARD.md',
      'RELEASING.md',
      'COMPATIBILITY.md',
      'protocol/CHANGELOG.md',
      'protocol/compatibility-matrix.v1.json',
      'protocol/schemas',
      _releaseContractCatalogPath,
    ]) {
      if (FileSystemEntity.typeSync('${repository.path}/$path') ==
          FileSystemEntityType.notFound) {
        throw StateError('Required release input is missing: $path');
      }
    }
  }

  void _validateOutputDirectory(Directory output) {
    final parent = output.parent;
    if (FileSystemEntity.typeSync(parent.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw ArgumentError(
        'Evidence output parent must already exist as a real directory: '
        '${parent.path}',
      );
    }
    _rejectSymlinkAncestors(parent.path);
    final resolvedOutput = _normalizeAbsolute(
      '${parent.resolveSymbolicLinksSync()}/${_baseName(output.path)}',
    );
    if (_isWithin(resolvedOutput, repository.path)) {
      throw ArgumentError(
        'Write release evidence outside the repository so generation cannot '
        'change candidate worktree identity: ${output.path}',
      );
    }
    final type = FileSystemEntity.typeSync(output.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw ArgumentError('Evidence output must not be a symlink.');
    }
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw ArgumentError('Evidence output is not a directory.');
    }
    if (output.existsSync() && output.listSync().isNotEmpty) {
      throw StateError(
        'Evidence output must be absent or empty; refusing to overwrite it: '
        '${output.path}',
      );
    }
  }

  void _createOutputDirectory(
    Directory output, {
    required bool privatePermissions,
  }) {
    if (!output.existsSync()) {
      if (privatePermissions) {
        final result = Process.runSync('mkdir', <String>[
          '-m',
          '700',
          output.path,
        ]);
        if (result.exitCode != 0) {
          throw FileSystemException(
            'Could not create private evidence directory: ${result.stderr}',
            output.path,
          );
        }
      } else {
        output.createSync();
      }
    }
    if (privatePermissions) _setPosixMode(output.path, '700');
  }

  List<ReleaseArtifact> _validateArtifacts(List<ReleaseArtifact> artifacts) {
    final names = <String>{};
    final result = <ReleaseArtifact>[];
    for (final artifact in artifacts) {
      if (!_safeLogicalName(artifact.name)) {
        throw ArgumentError(
          'Artifact names must be single safe filenames: ${artifact.name}',
        );
      }
      if (!names.add(artifact.name)) {
        throw ArgumentError('Duplicate artifact name: ${artifact.name}');
      }
      final type = FileSystemEntity.typeSync(
        artifact.file.absolute.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.file) {
        throw ArgumentError(
          'Artifact must be an existing regular file, not a symlink: '
          '${artifact.name}',
        );
      }
      result.add(
        ReleaseArtifact(name: artifact.name, file: artifact.file.absolute),
      );
    }
    result.sort((left, right) => left.name.compareTo(right.name));
    return result;
  }

  Future<String> _requiredProbe(
    String executable,
    List<String> arguments,
  ) async {
    final result = await _commandRunner(executable, arguments, repository.path);
    if (result.exitCode != 0) {
      throw StateError(
        'Required command failed: $executable ${arguments.join(' ')}: '
        '${_boundedProbeFailure(result)}',
      );
    }
    return result.combinedOutput.trim();
  }

  (DateTime, String) _resolveTimestamp(
    int? sourceDateEpoch,
    int gitCommitEpoch,
  ) {
    final environmentEpoch = int.tryParse(
      _environment['SOURCE_DATE_EPOCH'] ?? '',
    );
    final epoch = sourceDateEpoch ?? environmentEpoch ?? gitCommitEpoch;
    if (epoch < 0) {
      throw ArgumentError('SOURCE_DATE_EPOCH must be non-negative.');
    }
    final source = sourceDateEpoch != null
        ? 'command_line'
        : environmentEpoch != null
        ? 'SOURCE_DATE_EPOCH'
        : 'candidate_commit_time';
    return (
      DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true),
      source,
    );
  }

  List<File> _discoverSourceEvidenceFiles() {
    final files = <File>[];
    void walk(Directory directory) {
      final entities = directory.listSync(followLinks: false)
        ..sort((left, right) => left.path.compareTo(right.path));
      for (final entity in entities) {
        final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
        if (type == FileSystemEntityType.link) {
          final relative = _relativeEntityPath(entity.path);
          if (_isReleaseInputPath(relative)) {
            throw StateError('Release input must not be a symlink: $relative');
          }
          continue;
        }
        if (type == FileSystemEntityType.directory) {
          if (_ignoredDirectory(_baseName(entity.path))) continue;
          walk(Directory(entity.path));
          continue;
        }
        if (type != FileSystemEntityType.file) continue;
        final relative = _relativeEntityPath(entity.path);
        if (_isReleaseInputPath(relative)) files.add(File(entity.path));
      }
    }

    walk(repository);
    files.sort(
      (left, right) => _relativePath(left).compareTo(_relativePath(right)),
    );
    return files;
  }

  bool _isReleaseInputPath(String relative) {
    if (const <String>{
      'COMPATIBILITY.md',
      'QUALITY_STANDARD.md',
      'RELEASING.md',
      'SECURITY.md',
    }.contains(relative)) {
      return true;
    }
    if (relative.startsWith('protocol/schemas/') &&
        relative.endsWith('.json')) {
      return true;
    }
    if (const <String>{
      '.github/workflows/ci.yml',
      'protocol/compatibility-matrix.v1.json',
      _releaseContractCatalogPath,
      'packages/flutter_scout/lib/src/cli_protocol.dart',
      'packages/flutter_scout_helper/lib/src/flutter_scout_binding.dart',
      'packages/flutter_scout_helper/lib/src/runtime_protocol.dart',
    }.contains(relative)) {
      return true;
    }
    final base = _baseName(relative);
    return base == 'pubspec.yaml' ||
        base == 'pubspec.lock' ||
        base == 'CHANGELOG.md';
  }

  Map<String, Object?> _readPubspecIdentity(File file) {
    String? name;
    String? version;
    String? publishTo;
    for (final line in file.readAsLinesSync()) {
      if (line.startsWith('name:')) {
        name = _yamlScalar(line.substring('name:'.length));
      } else if (line.startsWith('version:')) {
        version = _yamlScalar(line.substring('version:'.length));
      } else if (line.startsWith('publish_to:')) {
        publishTo = _yamlScalar(line.substring('publish_to:'.length));
      }
    }
    return <String, Object?>{
      'path': _relativePath(file),
      'name': name,
      'version': version,
      'publishTo': publishTo,
      'sha256': sha256File(file),
    };
  }

  Map<String, Object?> _readProtocolIdentity() {
    final cliFile = File(
      '${repository.path}/packages/flutter_scout/lib/src/cli_protocol.dart',
    );
    final helperFile = File(
      '${repository.path}/packages/flutter_scout_helper/lib/src/'
      'flutter_scout_binding.dart',
    );
    final responseSchema = File(
      '${repository.path}/protocol/schemas/v1/response.schema.json',
    );
    final schemaDocument = jsonDecode(responseSchema.readAsStringSync());
    final properties = schemaDocument is Map
        ? schemaDocument['properties']
        : null;
    final capabilities = properties is Map ? properties['capabilities'] : null;
    final capabilityRequired = capabilities is Map
        ? capabilities['required']
        : null;
    final requiredCapabilities = capabilityRequired is List
        ? capabilityRequired.map((value) => value.toString()).toList()
        : <String>[];
    requiredCapabilities.sort();
    return <String, Object?>{
      'cli': <String, Object?>{
        'schemaVersion': _readDartIntConstant(
          cliFile,
          '_scoutCliSchemaVersion',
        ),
        'minimumProtocolVersion': _readDartIntConstant(
          cliFile,
          '_scoutCliProtocolMin',
        ),
        'maximumProtocolVersion': _readDartIntConstant(
          cliFile,
          '_scoutCliProtocolMax',
        ),
      },
      'helper': <String, Object?>{
        'schemaVersion': _readDartIntConstant(
          helperFile,
          'scoutHelperSchemaVersion',
        ),
        'protocolVersion': _readDartIntConstant(
          helperFile,
          'scoutHelperProtocolVersion',
        ),
        'minimumProtocolVersion': _readDartIntConstant(
          helperFile,
          'scoutHelperMinSupportedProtocolVersion',
        ),
        'maximumProtocolVersion': _readDartIntConstant(
          helperFile,
          'scoutHelperMaxSupportedProtocolVersion',
        ),
      },
      'requiredCapabilitiesFromResponseSchema': requiredCapabilities,
      'identitySourceSha256': <String, String>{
        _relativePath(cliFile): sha256File(cliFile),
        _relativePath(helperFile): sha256File(helperFile),
        _relativePath(responseSchema): sha256File(responseSchema),
      },
    };
  }

  int _readDartIntConstant(File file, String name) {
    final match = RegExp(
      'const\\s+int\\s+${RegExp.escape(name)}\\s*=\\s*([0-9]+)\\s*;',
    ).firstMatch(file.readAsStringSync());
    final value = match == null ? null : int.tryParse(match.group(1)!);
    if (value == null) {
      throw FormatException(
        'Could not read protocol constant `$name` from ${_relativePath(file)}.',
      );
    }
    return value;
  }

  Map<String, Object?> _buildDependencyInventory({
    required List<File> lockFiles,
    required DateTime generatedAt,
    required String candidateCommit,
  }) {
    final componentBuilders = <String, _ComponentBuilder>{};
    final lockfileRecords = <Map<String, Object?>>[];
    for (final lockFile in lockFiles) {
      final relative = _relativePath(lockFile);
      final packages = _parseLockfile(lockFile);
      lockfileRecords.add(<String, Object?>{
        'path': relative,
        'sha256': sha256File(lockFile),
        'resolvedComponentCount': packages.length,
      });
      for (final package in packages) {
        final key = package.source == 'path'
            ? '${package.identityKey}\u0000$relative'
            : package.identityKey;
        final builder = componentBuilders.putIfAbsent(
          key,
          () => _ComponentBuilder(package, identityKey: key),
        );
        builder.lockfiles.add(relative);
        builder.dependencyKinds.add(package.dependency);
      }
    }
    lockfileRecords.sort(
      (left, right) =>
          (left['path']! as String).compareTo(right['path']! as String),
    );
    final components = componentBuilders.values.toList()
      ..sort((left, right) => left.bomRef.compareTo(right.bomRef));
    return <String, Object?>{
      'bomFormat': 'CycloneDX',
      'specVersion': '1.5',
      'version': 1,
      'metadata': <String, Object?>{
        'timestamp': generatedAt.toIso8601String(),
        'component': <String, Object?>{
          'type': 'application',
          'bom-ref': 'git:$candidateCommit',
          'name': 'flutter_scout_repository',
          'version': candidateCommit,
        },
        'properties': <Map<String, String>>[
          <String, String>{
            'name': 'flutter-scout:inventory-source',
            'value': 'pubspec.lock files only; no network resolution',
          },
          <String, String>{
            'name': 'flutter-scout:dependency-graph',
            'value':
                'not represented because pubspec.lock does not preserve full '
                'dependency edges',
          },
        ],
      },
      'components': components.map((builder) => builder.toCycloneDx()).toList(),
      'properties': <Map<String, String>>[
        for (final lockfile in lockfileRecords)
          <String, String>{
            'name': 'flutter-scout:lockfile:${lockfile['path']}',
            'value': jsonEncode(_canonicalize(lockfile)),
          },
      ],
    };
  }

  List<_LockedPackage> _parseLockfile(File file) {
    final result = <_LockedPackage>[];
    var inPackages = false;
    String? name;
    String dependency = 'unknown';
    String source = 'unknown';
    String version = 'unknown';
    String? integrity;
    String? sourceUrl;
    String? sourcePath;
    String? sourceRef;

    void finish() {
      if (name == null) return;
      result.add(
        _LockedPackage(
          name: name!,
          dependency: dependency,
          source: source,
          version: version,
          integrity: integrity,
          sourceUrl: sourceUrl,
          sourcePath: sourcePath,
          sourceRef: sourceRef,
        ),
      );
      name = null;
      dependency = 'unknown';
      source = 'unknown';
      version = 'unknown';
      integrity = null;
      sourceUrl = null;
      sourcePath = null;
      sourceRef = null;
    }

    for (final line in file.readAsLinesSync()) {
      if (line == 'packages:') {
        inPackages = true;
        continue;
      }
      if (!inPackages) continue;
      if (line == 'sdks:') {
        finish();
        break;
      }
      final packageMatch = RegExp(r'^  ([A-Za-z0-9_.+\-]+):$').firstMatch(line);
      if (packageMatch != null) {
        finish();
        name = packageMatch.group(1)!;
        continue;
      }
      if (name == null) continue;
      final property = RegExp(
        r'^    (dependency|source|version):\s*(.*)$',
      ).firstMatch(line);
      if (property != null) {
        final value = _yamlScalar(property.group(2)!);
        switch (property.group(1)) {
          case 'dependency':
            dependency = value;
          case 'source':
            source = value;
          case 'version':
            version = value;
        }
        continue;
      }
      final description = RegExp(
        r'^      (sha256|url|path|resolved-ref):\s*(.*)$',
      ).firstMatch(line);
      if (description != null) {
        final value = _yamlScalar(description.group(2)!);
        switch (description.group(1)) {
          case 'sha256':
            integrity = value;
          case 'url':
            sourceUrl = value;
          case 'path':
            sourcePath = value;
          case 'resolved-ref':
            sourceRef = value;
        }
      }
    }
    finish();
    if (result.isEmpty) {
      throw FormatException(
        'Lockfile contains no resolved packages: ${_relativePath(file)}',
      );
    }
    for (final package in result) {
      if (package.dependency == 'unknown' ||
          package.source == 'unknown' ||
          package.version == 'unknown') {
        throw FormatException(
          'Incomplete lockfile component `${package.name}` in '
          '${_relativePath(file)}.',
        );
      }
      if (package.source == 'hosted' && package.integrity == null) {
        throw FormatException(
          'Hosted lockfile component `${package.name}` has no SHA-256 in '
          '${_relativePath(file)}.',
        );
      }
    }
    return result;
  }

  Map<String, Object?> _dartProvenance(ReleaseProbeResult probe) {
    return <String, Object?>{
      'runtimeVersion': _dartRuntimeVersion,
      'command': 'dart --version',
      'exitCode': probe.exitCode,
      'reportedVersion': probe.exitCode == 0 ? probe.combinedOutput : null,
      'collectionError': probe.exitCode == 0
          ? null
          : _boundedProbeFailure(probe),
    };
  }

  Map<String, Object?> _flutterProvenance(ReleaseProbeResult probe) {
    Object? machine;
    if (probe.exitCode == 0) {
      try {
        final parsed = jsonDecode(probe.stdout);
        if (parsed is Map) {
          machine = <String, Object?>{
            for (final key in const <String>[
              'frameworkVersion',
              'channel',
              'repositoryUrl',
              'frameworkRevision',
              'frameworkCommitDate',
              'engineRevision',
              'dartSdkVersion',
              'devToolsVersion',
            ])
              if (parsed.containsKey(key)) key: parsed[key],
          };
        }
      } on FormatException {
        machine = <String, Object?>{
          'unparsedOutputSha256': sha256Bytes(utf8.encode(probe.stdout)),
          'unparsedOutputReason':
              'flutter --version --machine did not return JSON',
        };
      }
    }
    return <String, Object?>{
      'command': 'flutter --version --machine',
      'exitCode': probe.exitCode,
      'machine': machine,
      'collectionError': probe.exitCode == 0
          ? null
          : _boundedProbeFailure(probe),
    };
  }

  String? _readBlockingFlutterPin() {
    final workflow = File('${repository.path}/.github/workflows/ci.yml');
    if (!workflow.existsSync()) return null;
    final match = RegExp(
      r'''flutter-version:\s*['"]([^'"]+)['"]''',
    ).firstMatch(workflow.readAsStringSync());
    return match?.group(1);
  }

  Map<String, Object?> _ciProvenance() {
    final repositoryName = _environment['GITHUB_REPOSITORY'];
    final runId = _environment['GITHUB_RUN_ID'];
    final server = _environment['GITHUB_SERVER_URL'];
    return <String, Object?>{
      'provider': _environment['GITHUB_ACTIONS'] == 'true'
          ? 'github_actions'
          : null,
      'workflow': _environment['GITHUB_WORKFLOW'],
      'job': _environment['GITHUB_JOB'],
      'runId': runId,
      'runAttempt': _environment['GITHUB_RUN_ATTEMPT'],
      'sha': _environment['GITHUB_SHA'],
      'ref': _environment['GITHUB_REF'],
      'runUrl': server != null && repositoryName != null && runId != null
          ? '$server/$repositoryName/actions/runs/$runId'
          : null,
      'missingReason': _environment['GITHUB_ACTIONS'] == 'true'
          ? null
          : 'Generator was not run in GitHub Actions.',
    };
  }

  String _relativePath(File file) => _relativeEntityPath(file.absolute.path);

  String _relativeEntityPath(String path) {
    final absolute = _normalizeAbsolute(path);
    if (!_isWithin(absolute, repository.path)) {
      throw ArgumentError('Path is outside repository: $absolute');
    }
    if (absolute == repository.path) return '.';
    return absolute.substring(repository.path.length + 1).replaceAll('\\', '/');
  }
}

Future<ReleaseProbeResult> runReleaseProbe(
  String executable,
  List<String> arguments,
  String workingDirectory,
) async {
  try {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: const <String, String>{
        'CI': 'true',
        'FLUTTER_SUPPRESS_ANALYTICS': 'true',
      },
      includeParentEnvironment: true,
      runInShell: false,
    );
    final stdoutFuture = utf8.decoder.bind(process.stdout).join();
    final stderrFuture = utf8.decoder.bind(process.stderr).join();
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      process.kill();
      return const ReleaseProbeResult(
        exitCode: 124,
        stdout: '',
        stderr: 'command timed out after 30 seconds',
      );
    }
    return ReleaseProbeResult(
      exitCode: exitCode,
      stdout: await stdoutFuture,
      stderr: await stderrFuture,
    );
  } on ProcessException catch (error) {
    return ReleaseProbeResult(exitCode: 127, stdout: '', stderr: error.message);
  }
}

String sha256File(File file) {
  final type = FileSystemEntity.typeSync(file.path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw ArgumentError('SHA-256 input is not a regular file: ${file.path}');
  }
  return sha256Bytes(file.readAsBytesSync());
}

String sha256Bytes(List<int> input) {
  const initial = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  const round = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  const mask = 0xffffffff;
  final bytes = <int>[...input, 0x80];
  while (bytes.length % 64 != 56) {
    bytes.add(0);
  }
  final bitLength = input.length * 8;
  for (var shift = 56; shift >= 0; shift -= 8) {
    bytes.add((bitLength >> shift) & 0xff);
  }

  final hash = <int>[...initial];
  final words = Uint32List(64);
  for (var offset = 0; offset < bytes.length; offset += 64) {
    for (var index = 0; index < 16; index += 1) {
      final start = offset + index * 4;
      words[index] =
          (bytes[start] << 24) |
          (bytes[start + 1] << 16) |
          (bytes[start + 2] << 8) |
          bytes[start + 3];
    }
    for (var index = 16; index < 64; index += 1) {
      final s0 =
          _rotateRight(words[index - 15], 7) ^
          _rotateRight(words[index - 15], 18) ^
          (words[index - 15] >> 3);
      final s1 =
          _rotateRight(words[index - 2], 17) ^
          _rotateRight(words[index - 2], 19) ^
          (words[index - 2] >> 10);
      words[index] = (words[index - 16] + s0 + words[index - 7] + s1) & mask;
    }

    var a = hash[0];
    var b = hash[1];
    var c = hash[2];
    var d = hash[3];
    var e = hash[4];
    var f = hash[5];
    var g = hash[6];
    var h = hash[7];
    for (var index = 0; index < 64; index += 1) {
      final sum1 =
          _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
      final choose = (e & f) ^ ((~e) & g);
      final temp1 = (h + sum1 + choose + round[index] + words[index]) & mask;
      final sum0 =
          _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (sum0 + majority) & mask;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & mask;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & mask;
    }
    hash[0] = (hash[0] + a) & mask;
    hash[1] = (hash[1] + b) & mask;
    hash[2] = (hash[2] + c) & mask;
    hash[3] = (hash[3] + d) & mask;
    hash[4] = (hash[4] + e) & mask;
    hash[5] = (hash[5] + f) & mask;
    hash[6] = (hash[6] + g) & mask;
    hash[7] = (hash[7] + h) & mask;
  }
  return hash.map((word) => word.toRadixString(16).padLeft(8, '0')).join();
}

int _rotateRight(int value, int count) =>
    ((value >> count) | (value << (32 - count))) & 0xffffffff;

final class _LockedPackage {
  const _LockedPackage({
    required this.name,
    required this.dependency,
    required this.source,
    required this.version,
    required this.integrity,
    required this.sourceUrl,
    required this.sourcePath,
    required this.sourceRef,
  });

  final String name;
  final String dependency;
  final String source;
  final String version;
  final String? integrity;
  final String? sourceUrl;
  final String? sourcePath;
  final String? sourceRef;

  String get identityKey => <String>[
    source,
    name,
    version,
    integrity ?? '',
    sourceUrl ?? '',
    sourcePath ?? '',
    sourceRef ?? '',
  ].join('\u0000');
}

final class _ComponentBuilder {
  _ComponentBuilder(this.package, {required this.identityKey});

  final _LockedPackage package;
  final String identityKey;
  final Set<String> lockfiles = <String>{};
  final Set<String> dependencyKinds = <String>{};

  String get bomRef => <String>[
    'locked',
    package.source,
    package.name,
    package.version,
    (package.integrity ?? sha256Bytes(utf8.encode(identityKey))).substring(
      0,
      12,
    ),
  ].join(':');

  Map<String, Object?> toCycloneDx() {
    final sortedLocks = lockfiles.toList()..sort();
    final sortedKinds = dependencyKinds.toList()..sort();
    return <String, Object?>{
      'type': package.source == 'sdk' ? 'framework' : 'library',
      'bom-ref': bomRef,
      'name': package.name,
      'version': package.version,
      if (package.source == 'hosted')
        'purl':
            'pkg:pub/${Uri.encodeComponent(package.name)}@'
            '${Uri.encodeComponent(package.version)}',
      if (package.integrity != null)
        'hashes': <Map<String, String>>[
          <String, String>{'alg': 'SHA-256', 'content': package.integrity!},
        ],
      'properties': <Map<String, String>>[
        <String, String>{
          'name': 'flutter-scout:source',
          'value': package.source,
        },
        <String, String>{
          'name': 'flutter-scout:dependency-kinds',
          'value': sortedKinds.join(','),
        },
        <String, String>{
          'name': 'flutter-scout:lockfiles',
          'value': sortedLocks.join(','),
        },
        if (package.sourceUrl != null)
          <String, String>{
            'name': 'flutter-scout:source-url',
            'value': package.sourceUrl!,
          },
        if (package.sourcePath != null)
          <String, String>{
            'name': 'flutter-scout:source-path',
            'value': package.sourcePath!,
          },
        if (package.sourceRef != null)
          <String, String>{
            'name': 'flutter-scout:source-revision',
            'value': package.sourceRef!,
          },
        if (package.integrity != null)
          <String, String>{
            'name': 'flutter-scout:integrity-provenance',
            'value': 'pubspec.lock description.sha256',
          },
      ],
    };
  }
}

void _verifyChecksumFile(
  File checksumFile, {
  required File? Function(String name) resolve,
  required List<String> errors,
  required String label,
  bool missingResolverIsError = false,
}) {
  if (!checksumFile.existsSync()) {
    errors.add('${_baseName(checksumFile.path)} is missing');
    return;
  }
  var lineNumber = 0;
  for (final line in checksumFile.readAsLinesSync()) {
    lineNumber += 1;
    if (line.trim().isEmpty) continue;
    final match = RegExp(r'^([a-f0-9]{64})  (.+)$').firstMatch(line);
    if (match == null) {
      errors.add('$label checksum line $lineNumber is malformed');
      continue;
    }
    final expected = match.group(1)!;
    final name = match.group(2)!;
    if (!_safeRelativePath(name)) {
      errors.add('$label checksum path is unsafe: $name');
      continue;
    }
    final file = resolve(name);
    if (file == null) {
      if (missingResolverIsError) {
        errors.add('$label file was not supplied for verification: $name');
      }
      continue;
    }
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      errors.add('$label file is missing or not regular: $name');
    } else if (sha256File(file) != expected) {
      errors.add('$label checksum mismatch: $name');
    }
  }
}

List<int> _jsonBytes(Object? value) => utf8.encode(
  '${const JsonEncoder.withIndent('  ').convert(_canonicalize(value))}\n',
);

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalize(value[key]),
    };
  }
  if (value is List) return value.map(_canonicalize).toList();
  return value;
}

String _checksumLines(Map<String, String> digests) {
  final entries = digests.entries.toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  return entries.map((entry) => '${entry.value}  ${entry.key}\n').join();
}

void _writeAtomic(
  File destination,
  List<int> bytes, {
  required bool privatePermissions,
}) {
  final temporary = File('${destination.path}.tmp');
  if (temporary.existsSync()) {
    throw StateError(
      'Refusing to overwrite stale temporary file: ${temporary.path}',
    );
  }
  final sink = temporary.openSync(mode: FileMode.write);
  try {
    if (privatePermissions) _setPosixMode(temporary.path, '600');
    sink.writeFromSync(bytes);
    sink.flushSync();
  } finally {
    sink.closeSync();
  }
  temporary.renameSync(destination.path);
  if (privatePermissions) _setPosixMode(destination.path, '600');
}

void _setPosixMode(String path, String mode) {
  final result = Process.runSync('chmod', <String>[mode, path]);
  if (result.exitCode != 0) {
    throw FileSystemException(
      'Could not set owner-only mode $mode: ${result.stderr}',
      path,
    );
  }
}

void _rejectSymlinkAncestors(String path) {
  var current = Directory(_normalizeAbsolute(path));
  while (true) {
    if (FileSystemEntity.typeSync(current.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw ArgumentError(
        'Evidence output ancestors must not be symlinks: ${current.path}',
      );
    }
    final parent = current.parent;
    if (parent.path == current.path) return;
    current = parent;
  }
}

String _yamlScalar(String source) {
  final value = source.trim();
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    try {
      return jsonDecode(value) as String;
    } on FormatException {
      return value.substring(1, value.length - 1);
    }
  }
  if (value.length >= 2 && value.startsWith("'") && value.endsWith("'")) {
    return value.substring(1, value.length - 1).replaceAll("''", "'");
  }
  return value;
}

String _boundedProbeFailure(ReleaseProbeResult result) {
  final value = result.combinedOutput.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (value.isEmpty) return 'exit ${result.exitCode} with no diagnostic';
  return value.length <= 500 ? value : '${value.substring(0, 500)}…';
}

int _statusEntryCount(String status) => status.isEmpty
    ? 0
    : const LineSplitter()
          .convert(status)
          .where((line) => line.isNotEmpty)
          .length;

bool _safeLogicalName(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+\-]{0,127}$').hasMatch(value) &&
    value != '.' &&
    value != '..';

bool _safeRelativePath(String value) {
  if (value.isEmpty || value.startsWith('/') || value.contains('\\')) {
    return false;
  }
  return !value
      .split('/')
      .any((segment) => segment.isEmpty || segment == '.' || segment == '..');
}

bool _ignoredDirectory(String name) => const <String>{
  '.dart_tool',
  '.flutter_scout',
  '.git',
  '.idea',
  'build',
}.contains(name);

String _normalizeAbsolute(String path) =>
    File(path).absolute.uri.normalizePath().toFilePath();

String _canonicalExistingDirectory(Directory directory) {
  final absolute = Directory(_normalizeAbsolute(directory.path));
  if (!absolute.existsSync()) return absolute.path;
  return absolute.resolveSymbolicLinksSync();
}

String _canonicalOutputDestination(Directory directory) {
  final absolute = Directory(_normalizeAbsolute(directory.path));
  final parent = absolute.parent;
  if (!parent.existsSync()) return absolute.path;
  return _normalizeAbsolute(
    '${parent.resolveSymbolicLinksSync()}/${_baseName(absolute.path)}',
  );
}

bool _isWithin(String child, String parent) {
  final normalizedChild = _normalizeAbsolute(child);
  final normalizedParent = _normalizeAbsolute(parent);
  return normalizedChild == normalizedParent ||
      normalizedChild.startsWith('$normalizedParent${Platform.pathSeparator}');
}

String _baseName(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}
