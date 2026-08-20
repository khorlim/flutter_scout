part of 'release_evidence.dart';

const String _releaseContractCatalogPath =
    'tool/release/release-contracts.v1.json';

final class _ReleaseContractDocuments {
  const _ReleaseContractDocuments({
    required this.catalog,
    required this.schemaManifest,
    required this.alignment,
    required this.sbom,
    required this.provenanceStatement,
    required this.rollbackPlan,
  });

  final Map<String, Object?> catalog;
  final Map<String, Object?> schemaManifest;
  final Map<String, Object?> alignment;
  final Map<String, Object?> sbom;
  final Map<String, Object?> provenanceStatement;
  final Map<String, Object?> rollbackPlan;
}

_ReleaseContractDocuments _buildReleaseContractDocuments({
  required ReleaseEvidenceGenerator generator,
  required List<File> sourceFiles,
  required List<File> schemaFiles,
  required List<Map<String, Object?>> packageIdentities,
  required Map<String, Map<String, Object>> artifactDigests,
  required Map<String, Object?> dependencyInventory,
  required Map<String, Object?> protocolIdentity,
  required String candidateCommit,
  required String candidateTree,
  required DateTime generatedAt,
  required String schemaSetDigest,
  required String sourceSetDigest,
}) {
  final catalog = _readReleaseContractCatalog(generator.repository);
  final schemaManifest = _buildReleaseSchemaManifest(
    generator: generator,
    schemaFiles: schemaFiles,
    protocolIdentity: protocolIdentity,
    candidateCommit: candidateCommit,
    schemaSetDigest: schemaSetDigest,
    contractCatalog: catalog,
  );
  final alignment = _buildReleaseAlignment(
    generator: generator,
    packageIdentities: packageIdentities,
    protocolIdentity: protocolIdentity,
    candidateCommit: candidateCommit,
  );
  final sbom = _buildReleaseSbom(
    packageIdentities: packageIdentities,
    artifactDigests: artifactDigests,
    dependencyInventory: dependencyInventory,
    candidateCommit: candidateCommit,
    generatedAt: generatedAt,
    schemaSetDigest: schemaSetDigest,
  );
  final provenanceStatement = _buildReleaseProvenanceStatement(
    artifactDigests: artifactDigests,
    candidateCommit: candidateCommit,
    candidateTree: candidateTree,
    generatedAt: generatedAt,
    schemaSetDigest: schemaSetDigest,
    sourceSetDigest: sourceSetDigest,
  );
  final rollbackPlan = _buildRollbackPlan(candidateCommit: candidateCommit);
  return _ReleaseContractDocuments(
    catalog: catalog,
    schemaManifest: schemaManifest,
    alignment: alignment,
    sbom: sbom,
    provenanceStatement: provenanceStatement,
    rollbackPlan: rollbackPlan,
  );
}

Map<String, Object?> _readReleaseContractCatalog(Directory repository) {
  final file = File('${repository.path}/$_releaseContractCatalogPath');
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw StateError('Required release contract catalog is missing.');
  }
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map ||
      decoded['artifactKind'] !=
          'flutter_scout_release_evidence_contract_catalog' ||
      decoded['formatVersion'] != 1 ||
      decoded['requiredEvidenceFiles'] is! List) {
    throw const FormatException(
      'release-contracts.v1.json has an unsupported contract.',
    );
  }
  final result = <String, Object?>{
    for (final entry in decoded.entries) entry.key.toString(): entry.value,
  };
  _requiredReleaseEvidenceNames(result);
  return result;
}

Set<String> _requiredReleaseEvidenceNames(Map<String, Object?> catalog) {
  final records = catalog['requiredEvidenceFiles'];
  if (records is! List) {
    throw const FormatException('Release contract file list is missing.');
  }
  final names = <String>{};
  for (final record in records) {
    if (record is! Map ||
        record['name'] is! String ||
        record['mediaType'] is! String ||
        record['contract'] is! String) {
      throw const FormatException('Release contract file record is invalid.');
    }
    final name = record['name']! as String;
    if (!_safeLogicalName(name) || !names.add(name)) {
      throw FormatException(
        'Release contract filename is unsafe or duplicated: $name',
      );
    }
  }
  return names;
}

Map<String, Object?> _buildReleaseSchemaManifest({
  required ReleaseEvidenceGenerator generator,
  required List<File> schemaFiles,
  required Map<String, Object?> protocolIdentity,
  required String candidateCommit,
  required String schemaSetDigest,
  required Map<String, Object?> contractCatalog,
}) {
  final schemaVersion = _nestedInt(protocolIdentity, 'cli', 'schemaVersion');
  final protocolVersion = _nestedInt(
    protocolIdentity,
    'helper',
    'protocolVersion',
  );
  final identifiers = <String>{};
  final documents = <Map<String, Object?>>[];
  var directoryVersionsMatch = true;
  var catalogIdentitiesMatch = true;
  for (final file in schemaFiles) {
    final relative = generator._relativePath(file);
    final directoryMatch = RegExp(
      r'^protocol/schemas/v([0-9]+)/[^/]+\.json$',
    ).firstMatch(relative);
    if (directoryMatch == null) {
      throw FormatException('Unexpected protocol schema path: $relative');
    }
    final directoryVersion = int.parse(directoryMatch.group(1)!);
    directoryVersionsMatch &= directoryVersion == schemaVersion;
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) {
      throw FormatException('Schema document is not an object: $relative');
    }
    final dialect = decoded[r'$schema'];
    final identifier = decoded[r'$id'];
    final documentKind = dialect == null ? 'typed_catalog' : 'json_schema';
    if (documentKind == 'json_schema') {
      if (dialect != 'https://json-schema.org/draft/2020-12/schema' ||
          identifier is! String ||
          !identifiers.add(identifier)) {
        throw FormatException(
          'JSON Schema dialect or identifier is invalid: $relative',
        );
      }
    }
    final catalogSchema = decoded['schemaVersion'];
    final catalogProtocol = decoded['protocolVersion'];
    if (catalogSchema != null) {
      catalogIdentitiesMatch &= catalogSchema == schemaVersion;
    }
    if (catalogProtocol != null) {
      catalogIdentitiesMatch &= catalogProtocol == protocolVersion;
    }
    documents.add(<String, Object?>{
      'path': relative,
      'sha256': sha256File(file),
      'schemaDirectoryVersion': directoryVersion,
      'documentKind': documentKind,
      'dialect': dialect,
      'identifier': identifier,
      'title': decoded['title'],
      'declaredSchemaVersion': catalogSchema,
      'declaredProtocolVersion': catalogProtocol,
    });
  }
  documents.sort(
    (left, right) =>
        (left['path']! as String).compareTo(right['path']! as String),
  );
  if (documents.isEmpty || !directoryVersionsMatch || !catalogIdentitiesMatch) {
    throw StateError(
      'Protocol schema files do not align with the live schema/protocol identity.',
    );
  }
  return <String, Object?>{
    'releaseSchemaManifestFormatVersion': 1,
    'candidateCommit': candidateCommit,
    'schemaVersion': schemaVersion,
    'protocolVersion': protocolVersion,
    'aggregateAlgorithm': 'SHA-256 over sorted path, NUL, digest, LF records',
    'aggregateSha256': schemaSetDigest,
    'documents': documents,
    'releaseEvidenceContractCatalog': <String, Object?>{
      'sourcePath': _releaseContractCatalogPath,
      'sha256': sha256File(
        File('${generator.repository.path}/$_releaseContractCatalogPath'),
      ),
      'formatVersion': contractCatalog['formatVersion'],
      'requiredEvidenceFiles': _requiredReleaseEvidenceNames(
        contractCatalog,
      ).toList()..sort(),
    },
    'validation': <String, Object?>{
      'allDocumentsValidJsonObjects': true,
      'jsonSchemaDialect': 'https://json-schema.org/draft/2020-12/schema',
      'jsonSchemaIdentifiersUnique': true,
      'schemaDirectoryVersionsMatchRuntime': directoryVersionsMatch,
      'typedCatalogIdentitiesMatchRuntime': catalogIdentitiesMatch,
    },
    'immutability': <String, Object?>{
      'state': 'candidate_digest_bound_not_signed',
      'releaseEstablished': false,
      'missingReason':
          'A deterministic digest does not establish publication immutability; '
          'the verified manifest must be bound to an immutable signed tag.',
    },
  };
}

Map<String, Object?> _buildReleaseAlignment({
  required ReleaseEvidenceGenerator generator,
  required List<Map<String, Object?>> packageIdentities,
  required Map<String, Object?> protocolIdentity,
  required String candidateCommit,
}) {
  final releasePackages =
      packageIdentities.where((identity) {
        return identity['name'] == 'flutter_scout' ||
            identity['name'] == 'flutter_scout_helper';
      }).toList()..sort(
        (left, right) =>
            (left['name']! as String).compareTo(right['name']! as String),
      );
  if (releasePackages.length != 2) {
    throw StateError('CLI/helper release package identities are missing.');
  }
  final packageRecords = <Map<String, Object?>>[];
  for (final identity in releasePackages) {
    final pubspecPath = identity['path']! as String;
    final packageDirectory = pubspecPath.substring(
      0,
      pubspecPath.lastIndexOf('/'),
    );
    final changelogPath = '$packageDirectory/CHANGELOG.md';
    final changelog = File('${generator.repository.path}/$changelogPath');
    if (FileSystemEntity.typeSync(changelog.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Package changelog is missing: $changelogPath');
    }
    final text = changelog.readAsStringSync();
    final firstSection = _firstMarkdownH2(text);
    final version = identity['version']! as String;
    packageRecords.add(<String, Object?>{
      'name': identity['name'],
      'version': version,
      'pubspecPath': pubspecPath,
      'pubspecSha256': identity['sha256'],
      'changelogPath': changelogPath,
      'changelogSha256': sha256File(changelog),
      'firstSection': firstSection,
      'hasUnreleasedSection': firstSection == 'Unreleased',
      'mentionsDeclaredVersion': text.contains(version),
      'isPrereleaseVersion': version.contains('-'),
      'hasDatedReleaseHeading': RegExp(
        '^##\\s+${RegExp.escape(version)}\\s+-\\s+[0-9]{4}-[0-9]{2}-[0-9]{2}\\s*\$',
        multiLine: true,
      ).hasMatch(text),
    });
  }

  final protocolChangelogPath = 'protocol/CHANGELOG.md';
  final protocolChangelog = File(
    '${generator.repository.path}/$protocolChangelogPath',
  );
  if (FileSystemEntity.typeSync(protocolChangelog.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw StateError('Protocol changelog is missing.');
  }
  final protocolText = protocolChangelog.readAsStringSync();
  final schemaVersion = _nestedInt(protocolIdentity, 'cli', 'schemaVersion');
  final protocolVersion = _nestedInt(
    protocolIdentity,
    'helper',
    'protocolVersion',
  );

  final compatibilityPath = 'protocol/compatibility-matrix.v1.json';
  final compatibilityFile = File(
    '${generator.repository.path}/$compatibilityPath',
  );
  final matrixDecoded = jsonDecode(compatibilityFile.readAsStringSync());
  if (matrixDecoded is! Map || matrixDecoded['currentContract'] is! Map) {
    throw const FormatException('Compatibility matrix contract is invalid.');
  }
  final current = matrixDecoded['currentContract']! as Map;
  final cliPackage = current['cliPackage'];
  final helperPackage = current['helperPackage'];
  final cliIdentity = releasePackages.firstWhere(
    (entry) => entry['name'] == 'flutter_scout',
  );
  final helperIdentity = releasePackages.firstWhere(
    (entry) => entry['name'] == 'flutter_scout_helper',
  );
  final matrixChecks = <String, bool>{
    'cliPackageVersion':
        cliPackage is Map && cliPackage['version'] == cliIdentity['version'],
    'helperPackageVersion':
        helperPackage is Map &&
        helperPackage['version'] == helperIdentity['version'],
    'schemaVersion': current['schemaVersion'] == schemaVersion,
    'protocolVersion': current['protocolVersion'] == protocolVersion,
    'cliMinimumProtocol':
        (current['cliSupportedProtocolRange'] as Map?)?['minimum'] ==
        _nestedInt(protocolIdentity, 'cli', 'minimumProtocolVersion'),
    'cliMaximumProtocol':
        (current['cliSupportedProtocolRange'] as Map?)?['maximum'] ==
        _nestedInt(protocolIdentity, 'cli', 'maximumProtocolVersion'),
    'helperMinimumProtocol':
        (current['helperSupportedProtocolRange'] as Map?)?['minimum'] ==
        _nestedInt(protocolIdentity, 'helper', 'minimumProtocolVersion'),
    'helperMaximumProtocol':
        (current['helperSupportedProtocolRange'] as Map?)?['maximum'] ==
        _nestedInt(protocolIdentity, 'helper', 'maximumProtocolVersion'),
  };
  final compatibilityPolicy = File(
    '${generator.repository.path}/COMPATIBILITY.md',
  );
  final policyText = compatibilityPolicy.readAsStringSync();
  final checks = <String, bool>{
    'cliChangelogHasUnreleasedIntent':
        packageRecords.firstWhere(
          (entry) => entry['name'] == 'flutter_scout',
        )['hasUnreleasedSection'] ==
        true,
    'helperChangelogHasUnreleasedIntent':
        packageRecords.firstWhere(
          (entry) => entry['name'] == 'flutter_scout_helper',
        )['hasUnreleasedSection'] ==
        true,
    'packageVersionsMentionedInChangelogs': packageRecords.every(
      (entry) => entry['mentionsDeclaredVersion'] == true,
    ),
    'protocolChangelogHasUnreleasedIntent':
        _firstMarkdownH2(protocolText) == 'Unreleased',
    'protocolChangelogMentionsSchema': RegExp(
      'schema[- ]$schemaVersion',
      caseSensitive: false,
    ).hasMatch(protocolText),
    'protocolChangelogMentionsProtocol': RegExp(
      'protocol[- ]$protocolVersion',
      caseSensitive: false,
    ).hasMatch(protocolText),
    'compatibilityMatrixMatchesSource': matrixChecks.values.every(
      (value) => value,
    ),
    'upgradeNotesPresent': policyText.contains('## Upgrade procedure'),
    'downgradeNotesPresent': policyText.contains(
      '## Downgrade and rollback compatibility',
    ),
  };
  final sourceIntentAligned = checks.values.every((value) => value);
  final releaseFinalized = packageRecords.every(
    (entry) =>
        entry['isPrereleaseVersion'] == false &&
        entry['hasDatedReleaseHeading'] == true,
  );
  return <String, Object?>{
    'releaseAlignmentFormatVersion': 1,
    'candidateCommit': candidateCommit,
    'packages': packageRecords,
    'protocolChangelog': <String, Object?>{
      'path': protocolChangelogPath,
      'sha256': sha256File(protocolChangelog),
      'firstSection': _firstMarkdownH2(protocolText),
      'schemaVersion': schemaVersion,
      'protocolVersion': protocolVersion,
    },
    'compatibility': <String, Object?>{
      'matrixPath': compatibilityPath,
      'matrixSha256': sha256File(compatibilityFile),
      'matrixReleaseRatified':
          (matrixDecoded['evidenceScope'] as Map?)?['releaseRatified'],
      'sourceIdentityChecks': matrixChecks,
      'policyPath': 'COMPATIBILITY.md',
      'policySha256': sha256File(compatibilityPolicy),
      'upgradeNotesPresent': checks['upgradeNotesPresent'],
      'downgradeNotesPresent': checks['downgradeNotesPresent'],
    },
    'checks': checks,
    'sourceIntentAligned': sourceIntentAligned,
    'releaseFinalized': releaseFinalized,
    'releaseEligibilityEstablished': false,
    'status': sourceIntentAligned
        ? releaseFinalized
              ? 'source_release_identity_aligned_unratified'
              : 'source_intent_aligned_release_not_finalized'
        : 'source_alignment_failed',
    'missingReleaseEvidence': <String>[
      if (!releaseFinalized)
        'CLI/helper versions and dated changelog headings are not finalized.',
      'A signed tag, retained release-binary compatibility exercise, and all '
          'other RELEASING.md gates remain independently required.',
    ],
  };
}

Map<String, Object?> _buildReleaseSbom({
  required List<Map<String, Object?>> packageIdentities,
  required Map<String, Map<String, Object>> artifactDigests,
  required Map<String, Object?> dependencyInventory,
  required String candidateCommit,
  required DateTime generatedAt,
  required String schemaSetDigest,
}) {
  final components = <Map<String, Object?>>[];
  final inventoryComponents = dependencyInventory['components'];
  if (inventoryComponents is! List) {
    throw const FormatException('Dependency inventory has no components.');
  }
  for (final component in inventoryComponents) {
    if (component is! Map) {
      throw const FormatException('Dependency inventory component is invalid.');
    }
    components.add(<String, Object?>{
      for (final entry in component.entries) entry.key.toString(): entry.value,
    });
  }
  final assemblyRefs = <String>[];
  for (final package in packageIdentities) {
    final name = package['name']! as String;
    final version = package['version'] as String? ?? 'unversioned';
    final ref = 'source-package:$name@$version';
    assemblyRefs.add(ref);
    components.add(<String, Object?>{
      'type': name == 'scout_test_app' ? 'application' : 'library',
      'bom-ref': ref,
      'name': name,
      'version': version,
      'hashes': <Map<String, String>>[
        <String, String>{
          'alg': 'SHA-256',
          'content': package['sha256']! as String,
        },
      ],
      'properties': <Map<String, String>>[
        <String, String>{
          'name': 'flutter-scout:component-source',
          'value': package['path']! as String,
        },
        const <String, String>{
          'name': 'flutter-scout:hash-subject',
          'value': 'pubspec.yaml source identity, not a published archive',
        },
      ],
    });
  }
  for (final entry in artifactDigests.entries) {
    final ref = 'release-artifact:${entry.key}';
    assemblyRefs.add(ref);
    components.add(<String, Object?>{
      'type': 'file',
      'bom-ref': ref,
      'name': entry.key,
      'hashes': <Map<String, String>>[
        <String, String>{
          'alg': 'SHA-256',
          'content': entry.value['sha256']! as String,
        },
      ],
      'properties': <Map<String, String>>[
        <String, String>{
          'name': 'flutter-scout:size-bytes',
          'value': entry.value['size'].toString(),
        },
      ],
    });
  }
  components.sort(
    (left, right) =>
        (left['bom-ref']! as String).compareTo(right['bom-ref']! as String),
  );
  final refs = <String>{};
  for (final component in components) {
    final ref = component['bom-ref'];
    if (ref is! String || !refs.add(ref)) {
      throw StateError(
        'CycloneDX component reference is missing or duplicated.',
      );
    }
  }
  assemblyRefs.sort();
  final artifactSetDigest = _releaseAggregateDigest(<String, String>{
    for (final entry in artifactDigests.entries)
      entry.key: entry.value['sha256']! as String,
  });
  return <String, Object?>{
    r'$schema': 'http://cyclonedx.org/schema/bom-1.5.schema.json',
    'bomFormat': 'CycloneDX',
    'specVersion': '1.5',
    'serialNumber': _deterministicSbomSerial(
      '$candidateCommit\u0000$schemaSetDigest\u0000$artifactSetDigest',
    ),
    'version': 1,
    'metadata': <String, Object?>{
      'timestamp': generatedAt.toIso8601String(),
      'tools': <Map<String, Object?>>[
        <String, Object?>{
          'vendor': 'Flutter Scout',
          'name': 'offline-release-evidence-generator',
          'version': '1',
        },
      ],
      'component': <String, Object?>{
        'type': 'application',
        'bom-ref': 'git:$candidateCommit',
        'name': 'flutter_scout_release_candidate',
        'version': candidateCommit,
      },
      'properties': <Map<String, String>>[
        const <String, String>{
          'name': 'flutter-scout:sbom-input',
          'value':
              'checked-in pubspec.lock/pubspec.yaml and supplied artifacts',
        },
        const <String, String>{
          'name': 'flutter-scout:network-access',
          'value': 'none',
        },
      ],
    },
    'components': components,
    'compositions': <Map<String, Object?>>[
      <String, Object?>{'aggregate': 'incomplete', 'assemblies': assemblyRefs},
    ],
    'properties': <Map<String, String>>[
      const <String, String>{
        'name': 'flutter-scout:composition-qualification',
        'value':
            'incomplete: lockfiles do not retain the full dependency edge '
            'graph, package licenses, or vulnerability findings',
      },
      <String, String>{
        'name': 'flutter-scout:schema-set-sha256',
        'value': schemaSetDigest,
      },
      <String, String>{
        'name': 'flutter-scout:artifact-set-sha256',
        'value': artifactSetDigest,
      },
    ],
  };
}

Map<String, Object?> _buildReleaseProvenanceStatement({
  required Map<String, Map<String, Object>> artifactDigests,
  required String candidateCommit,
  required String candidateTree,
  required DateTime generatedAt,
  required String schemaSetDigest,
  required String sourceSetDigest,
}) {
  final subjects = <Map<String, Object?>>[
    for (final entry in artifactDigests.entries)
      <String, Object?>{
        'name': entry.key,
        'digest': <String, String>{'sha256': entry.value['sha256']! as String},
      },
  ];
  if (subjects.isEmpty) {
    subjects.add(<String, Object?>{
      'name': 'flutter_scout_source_contract',
      'digest': <String, String>{'sha256': sourceSetDigest},
    });
  }
  return <String, Object?>{
    '_type': 'https://in-toto.io/Statement/v1',
    'subject': subjects,
    'predicateType': 'https://slsa.dev/provenance/v1',
    'predicate': <String, Object?>{
      'buildDefinition': <String, Object?>{
        'buildType':
            'https://flutter-scout.dev/release/offline-evidence-generation/v1',
        'externalParameters': <String, Object?>{
          'candidateCommit': candidateCommit,
          'candidateTree': candidateTree,
          'schemaSetSha256': schemaSetDigest,
          'sourceSetSha256': sourceSetDigest,
        },
        'internalParameters': <String, Object?>{
          'networkAccess': false,
          'artifactBytesModified': false,
        },
        'resolvedDependencies': <Map<String, Object?>>[
          <String, Object?>{
            'uri': 'git+local:flutter_scout@$candidateCommit',
            'digest': <String, String>{'sha256': sourceSetDigest},
          },
        ],
      },
      'runDetails': <String, Object?>{
        'builder': <String, String>{
          'id': 'https://flutter-scout.dev/release-evidence-generator/v1',
        },
        'metadata': <String, Object?>{
          'invocationId': sha256Bytes(
            utf8.encode(
              '$candidateCommit\u0000$sourceSetDigest\u0000$schemaSetDigest',
            ),
          ),
          'startedOn': generatedAt.toIso8601String(),
          'finishedOn': generatedAt.toIso8601String(),
        },
        'byproducts': const <Object?>[],
      },
      'flutterScoutQualification': <String, Object?>{
        'attestationState': 'unsigned_local_statement',
        'releaseEligibilityEstablished': false,
        'missingReason':
            'This deterministic local statement has not been signed or '
            'independently verified by an approved release identity.',
      },
    },
  };
}

Map<String, Object?> _buildReleaseArtifactDigestsDocument({
  required String candidateCommit,
  required Map<String, Map<String, Object>> artifactDigests,
}) {
  final aggregate = _releaseAggregateDigest(<String, String>{
    for (final entry in artifactDigests.entries)
      entry.key: entry.value['sha256']! as String,
  });
  return <String, Object?>{
    'artifactDigestFormatVersion': 1,
    'candidateCommit': candidateCommit,
    'algorithm': 'SHA-256',
    'aggregateAlgorithm': 'SHA-256 over sorted name, NUL, digest, LF records',
    'aggregateSha256': aggregate,
    'artifactCount': artifactDigests.length,
    'artifacts': artifactDigests,
    'releaseEligibilityEstablished': false,
    'missingReason': artifactDigests.isEmpty
        ? 'No release artifacts were supplied.'
        : 'Digests prove byte identity only; they do not prove build, '
              'signature, publication, or runtime qualification.',
  };
}

Map<String, Object?> _buildSigningVerificationContract({
  required String candidateCommit,
  required Map<String, String> boundEvidenceDigests,
}) {
  final sortedBindings = <String, String>{
    for (final entry
        in (boundEvidenceDigests.entries.toList()
          ..sort((left, right) => left.key.compareTo(right.key))))
      entry.key: entry.value,
  };
  return <String, Object?>{
    'signingVerificationFormatVersion': 1,
    'candidateCommit': candidateCommit,
    'manifestBinding': <String, Object?>{
      'manifestPath': 'manifest.json',
      'digestPath': 'manifest.sha256',
      'algorithm': 'SHA-256',
      'requiredAnnotatedTagMessageField': 'release-manifest-sha256',
      'preManifestEvidenceDigests': sortedBindings,
    },
    'signature': <String, Object?>{
      'state': 'not_performed',
      'tagName': null,
      'tagObjectId': null,
      'resolvedCommit': null,
      'signerFingerprint': null,
      'verificationTool': null,
      'verificationToolVersion': null,
      'verifiedManifestSha256': null,
    },
    'independentVerification': <String, Object?>{
      'state': 'not_performed',
      'environmentIdentity': null,
      'tagObjectId': null,
      'resolvedCommit': null,
      'signerFingerprint': null,
      'manifestSha256': null,
      'evidenceDigest': null,
    },
    'requiredVerificationChecks': const <String>[
      'tag_is_annotated_object',
      'tag_resolves_to_candidate_commit',
      'signature_cryptographically_valid',
      'signer_fingerprint_matches_independent_approved_key_record',
      'tag_message_binds_exact_manifest_sha256',
      'second_environment_fetches_and_verifies_same_tag_object',
    ],
    'releaseEligibilityEstablished': false,
    'missingReason':
        'Generation occurs before signing. No tag, signature, approved key, or '
        'independent verification is asserted by this file.',
  };
}

Map<String, Object?> _buildRollbackPlan({required String candidateCommit}) {
  return <String, Object?>{
    'rollbackPlanFormatVersion': 1,
    'candidateCommit': candidateCommit,
    'knownGoodRelease': <String, Object?>{
      'state': 'not_selected_or_verified',
      'tagName': null,
      'tagObjectId': null,
      'resolvedCommit': null,
      'signerFingerprint': null,
      'cliVersion': null,
      'helperVersion': null,
      'schemaVersion': null,
      'protocolVersion': null,
      'compatibilityEvidenceDigest': null,
    },
    'procedure': const <Map<String, Object?>>[
      <String, Object?>{
        'order': 1,
        'action': 'stop_candidate_distribution_preserve_tag_and_evidence',
      },
      <String, Object?>{
        'order': 2,
        'action': 'verify_known_good_tag_signature_and_resolved_commit',
      },
      <String, Object?>{
        'order': 3,
        'action': 'activate_cli_from_exact_known_good_tag',
      },
      <String, Object?>{
        'order': 4,
        'action':
            'pin_compatible_helper_and_full_debug_relaunch_without_data_reset',
      },
      <String, Object?>{
        'order': 5,
        'action':
            'verify_version_doctor_status_attach_inspect_guarded_action_evidence_cleanup',
      },
      <String, Object?>{
        'order': 6,
        'action': 'retain_candidate_failure_and_issue_new_patch_candidate',
      },
    ],
    'safetyInvariants': const <String>[
      'do_not_move_delete_or_reuse_the_candidate_tag',
      'do_not_reset_simulator_or_application_data',
      'do_not_kill_attach_only_or_unrelated_processes',
      'do_not_replay_an_uncertain_mutation',
      'stop_for_operator_action_when_ownership_or_compatibility_is_uncertain',
    ],
    'requiredExerciseEvidence': const <String>[
      'known_good_tag_signature_and_fingerprint',
      'candidate_to_known_good_cli_and_helper_transition',
      'full_helper_relaunch',
      'schema_protocol_and_capability_match',
      'one_uniquely_targeted_guarded_action_with_closed_outcomes',
      'evidence_collection_and_exact_owned_process_cleanup',
      'preservation_of_application_and_simulator_state',
    ],
    'exercise': <String, Object?>{
      'state': 'not_exercised',
      'environment': null,
      'startedAt': null,
      'completedAt': null,
      'evidenceDigests': const <Object?>[],
      'result': null,
    },
    'releaseEligibilityEstablished': false,
    'missingReason':
        'No signed known-good release or retained rollback exercise was '
        'provided to the offline generator.',
  };
}

void _verifyReleaseContractDocuments({
  required ReleaseEvidenceGenerator generator,
  required Directory directory,
  required Map manifest,
  required String currentCommit,
  required String currentTree,
  required Map<String, File> artifacts,
  required List<String> errors,
}) {
  Map<String, Object?>? readObject(String name) {
    try {
      final decoded = jsonDecode(
        File('${directory.path}/$name').readAsStringSync(),
      );
      if (decoded is! Map) {
        errors.add('$name is not a JSON object');
        return null;
      }
      return <String, Object?>{
        for (final entry in decoded.entries) entry.key.toString(): entry.value,
      };
    } on Object catch (error) {
      errors.add('$name could not be parsed: $error');
      return null;
    }
  }

  final sourceCatalog = _readReleaseContractCatalog(generator.repository);
  final requiredNames = _requiredReleaseEvidenceNames(sourceCatalog);
  final evidenceFiles = manifest['evidenceFiles'];
  if (evidenceFiles is! Map) return;
  for (final name in requiredNames) {
    if (!evidenceFiles.containsKey(name)) {
      errors.add('manifest is missing required release evidence file: $name');
    }
  }
  for (final name in evidenceFiles.keys.map((value) => value.toString())) {
    if (!requiredNames.contains(name)) {
      errors.add('manifest contains uncontracted release evidence file: $name');
    }
  }
  final emittedCatalog = readObject('release-contract-catalog.json');
  if (emittedCatalog != null &&
      jsonEncode(_canonicalize(emittedCatalog)) !=
          jsonEncode(_canonicalize(sourceCatalog))) {
    errors.add('release contract catalog does not match candidate source');
  }

  final provenance = readObject('provenance.json');
  final schemaManifest = readObject('release-schema-manifest.json');
  final alignment = readObject('release-alignment.json');
  final sbom = readObject('dependency-sbom.cdx.json');
  final inventory = readObject('dependency-inventory.cdx.json');
  final provenanceStatement = readObject('provenance-statement.intoto.json');
  final signing = readObject('signing-verification.json');
  final rollback = readObject('rollback-plan.json');
  final artifactsDocument = readObject('artifacts.json');
  if (<Object?>[
    provenance,
    schemaManifest,
    alignment,
    sbom,
    inventory,
    provenanceStatement,
    signing,
    rollback,
    artifactsDocument,
  ].any((value) => value == null)) {
    return;
  }
  final candidate = provenance!['candidate'];
  final candidateCommit = candidate is Map
      ? candidate['commit']?.toString()
      : null;
  final candidateTree = candidate is Map ? candidate['tree']?.toString() : null;
  if (candidateCommit == null || candidateTree == null) {
    errors.add('provenance candidate identity is incomplete');
    return;
  }
  if (candidateCommit != currentCommit ||
      candidateTree != currentTree ||
      manifest['candidateCommit'] != candidateCommit) {
    errors.add(
      'candidate commit/tree identity does not match verification checkout',
    );
  }
  for (final entry in <String, Map<String, Object?>>{
    'release-schema-manifest.json': schemaManifest!,
    'release-alignment.json': alignment!,
    'signing-verification.json': signing!,
    'rollback-plan.json': rollback!,
  }.entries) {
    if (entry.value['candidateCommit'] != candidateCommit) {
      errors.add('${entry.key} candidate commit does not match provenance');
    }
  }

  try {
    final sourceFiles = generator._discoverSourceEvidenceFiles();
    final schemaFiles = sourceFiles
        .where(
          (file) =>
              generator._relativePath(file).startsWith('protocol/schemas/'),
        )
        .toList(growable: false);
    final sourceDigests = <String, String>{
      for (final file in sourceFiles)
        generator._relativePath(file): sha256File(file),
    };
    final schemaDigests = <String, String>{
      for (final file in schemaFiles)
        generator._relativePath(file): sha256File(file),
    };
    final schemaSetDigest = _releaseAggregateDigest(schemaDigests);
    final sourceSetDigest = _releaseAggregateDigest(sourceDigests);
    final packageIdentities =
        <Map<String, Object?>>[
          for (final file in sourceFiles.where(
            (candidate) => _baseName(candidate.path) == 'pubspec.yaml',
          ))
            generator._readPubspecIdentity(file),
        ]..sort(
          (left, right) =>
              (left['path']! as String).compareTo(right['path']! as String),
        );
    final protocolIdentity = generator._readProtocolIdentity();
    if (jsonEncode(_canonicalize(provenance['packages'])) !=
        jsonEncode(_canonicalize(packageIdentities))) {
      errors.add('provenance package identities do not match candidate source');
    }
    if (jsonEncode(_canonicalize(provenance['protocol'])) !=
        jsonEncode(_canonicalize(protocolIdentity))) {
      errors.add(
        'provenance protocol identity does not match candidate source',
      );
    }
    final protocolSchemas = provenance['protocolSchemas'];
    if (protocolSchemas is! Map ||
        protocolSchemas['count'] != schemaFiles.length ||
        protocolSchemas['aggregateSha256'] != schemaSetDigest) {
      errors.add('provenance schema identity does not match candidate source');
    }
    final candidateFacts = provenance['candidate'];
    if (candidateFacts is! Map ||
        candidateFacts['cleanWorktree'] != true ||
        candidateFacts['worktreeStatusEntryCount'] != 0 ||
        candidateFacts['worktreeStatusSha256'] != sha256Bytes(const <int>[])) {
      errors.add('provenance does not describe a clean verification candidate');
    }
    final expectedSchemaManifest = _buildReleaseSchemaManifest(
      generator: generator,
      schemaFiles: schemaFiles,
      protocolIdentity: protocolIdentity,
      candidateCommit: candidateCommit,
      schemaSetDigest: schemaSetDigest,
      contractCatalog: sourceCatalog,
    );
    if (jsonEncode(_canonicalize(schemaManifest)) !=
        jsonEncode(_canonicalize(expectedSchemaManifest))) {
      errors.add(
        'release-schema-manifest.json does not match candidate source',
      );
    }
    final expectedAlignment = _buildReleaseAlignment(
      generator: generator,
      packageIdentities: packageIdentities,
      protocolIdentity: protocolIdentity,
      candidateCommit: candidateCommit,
    );
    if (jsonEncode(_canonicalize(alignment)) !=
        jsonEncode(_canonicalize(expectedAlignment))) {
      errors.add('release-alignment.json does not match candidate source');
    }
    final artifactDigestMap = <String, Map<String, Object>>{
      for (final entry in artifacts.entries)
        entry.key: <String, Object>{
          'sha256': sha256File(entry.value),
          'size': entry.value.lengthSync(),
        },
    };
    final generatedAt = DateTime.parse(provenance['generatedAt']! as String);
    final expectedInventory = generator._buildDependencyInventory(
      lockFiles: sourceFiles
          .where((file) => _baseName(file.path) == 'pubspec.lock')
          .toList(growable: false),
      generatedAt: generatedAt,
      candidateCommit: candidateCommit,
    );
    if (jsonEncode(_canonicalize(inventory)) !=
        jsonEncode(_canonicalize(expectedInventory))) {
      errors.add(
        'dependency-inventory.cdx.json does not match candidate lockfiles',
      );
    }
    final expectedSbom = _buildReleaseSbom(
      packageIdentities: packageIdentities,
      artifactDigests: artifactDigestMap,
      dependencyInventory: expectedInventory,
      candidateCommit: candidateCommit,
      generatedAt: generatedAt,
      schemaSetDigest: schemaSetDigest,
    );
    if (jsonEncode(_canonicalize(sbom)) !=
        jsonEncode(_canonicalize(expectedSbom))) {
      errors.add('dependency-sbom.cdx.json does not match verified inputs');
    }
    final expectedProvenanceStatement = _buildReleaseProvenanceStatement(
      artifactDigests: artifactDigestMap,
      candidateCommit: candidateCommit,
      candidateTree: candidateTree,
      generatedAt: generatedAt,
      schemaSetDigest: schemaSetDigest,
      sourceSetDigest: sourceSetDigest,
    );
    if (jsonEncode(_canonicalize(provenanceStatement)) !=
        jsonEncode(_canonicalize(expectedProvenanceStatement))) {
      errors.add(
        'provenance-statement.intoto.json does not match verified inputs',
      );
    }
    final expectedArtifacts = _buildReleaseArtifactDigestsDocument(
      candidateCommit: candidateCommit,
      artifactDigests: artifactDigestMap,
    );
    if (jsonEncode(_canonicalize(artifactsDocument)) !=
        jsonEncode(_canonicalize(expectedArtifacts))) {
      errors.add('artifacts.json does not match verified artifact bytes');
    }
  } on Object catch (error) {
    errors.add('release contract source verification failed: $error');
  }

  final expectedSigning = _buildSigningVerificationContract(
    candidateCommit: candidateCommit,
    boundEvidenceDigests: <String, String>{
      for (final entry in evidenceFiles.entries)
        if (entry.key.toString() != 'signing-verification.json')
          entry.key.toString(): entry.value.toString(),
    },
  );
  if (jsonEncode(_canonicalize(signing)) !=
      jsonEncode(_canonicalize(expectedSigning))) {
    errors.add(
      'signing-verification.json does not match the unsigned pre-sign contract',
    );
  }
  final expectedRollback = _buildRollbackPlan(candidateCommit: candidateCommit);
  if (jsonEncode(_canonicalize(rollback)) !=
      jsonEncode(_canonicalize(expectedRollback))) {
    errors.add('rollback-plan.json does not match the unexercised contract');
  }

  final signature = signing['signature'];
  final independent = signing['independentVerification'];
  if (signing['signingVerificationFormatVersion'] != 1 ||
      signature is! Map ||
      signature['state'] != 'not_performed' ||
      independent is! Map ||
      independent['state'] != 'not_performed' ||
      signing['releaseEligibilityEstablished'] != false) {
    errors.add(
      'signing-verification.json must remain an explicit unsigned pre-sign contract',
    );
  }
  final knownGood = rollback['knownGoodRelease'];
  final exercise = rollback['exercise'];
  if (rollback['rollbackPlanFormatVersion'] != 1 ||
      knownGood is! Map ||
      knownGood['state'] != 'not_selected_or_verified' ||
      exercise is! Map ||
      exercise['state'] != 'not_exercised' ||
      rollback['releaseEligibilityEstablished'] != false) {
    errors.add(
      'rollback-plan.json must not claim an unperformed rollback exercise',
    );
  }
}

int _nestedInt(Map<String, Object?> source, String parent, String child) {
  final nested = source[parent];
  final value = nested is Map ? nested[child] : null;
  if (value is! int) {
    throw FormatException('Missing integer identity: $parent.$child');
  }
  return value;
}

String? _firstMarkdownH2(String text) =>
    RegExp(r'^##\s+(.+?)\s*$', multiLine: true).firstMatch(text)?.group(1);

String _releaseAggregateDigest(Map<String, String> digests) {
  final entries = digests.entries.toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  return sha256Bytes(
    utf8.encode(
      entries.map((entry) => '${entry.key}\u0000${entry.value}\n').join(),
    ),
  );
}

String _deterministicSbomSerial(String seed) {
  final digest = sha256Bytes(utf8.encode(seed));
  final value =
      '${digest.substring(0, 8)}-'
      '${digest.substring(8, 12)}-'
      '5${digest.substring(13, 16)}-'
      '8${digest.substring(17, 20)}-'
      '${digest.substring(20, 32)}';
  return 'urn:uuid:$value';
}
